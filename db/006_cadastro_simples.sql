-- Cadastro de um passo so: "me lembre de tomar X as 11h" ja cria o item. A quantidade e opcional.
SET search_path = agente;

ALTER TABLE supplies ALTER COLUMN units_total DROP NOT NULL;

-- Estoque sem quantidade informada: restante e data de acabar ficam em branco (sem aviso de compra).
DROP VIEW IF EXISTS supplies_status;
CREATE VIEW supplies_status AS
SELECT x.*, x.runs_out_on - x.alert_days AS alert_on
FROM (
  SELECT s.*,
    CASE WHEN s.units_total IS NULL THEN NULL
         WHEN s.take_time IS NOT NULL
         THEN GREATEST(0, s.units_total - COALESCE(d.taken, 0) * s.units_per_day)
         ELSE GREATEST(0, s.units_total - ((CURRENT_DATE - s.started_on) - s.paused_days) * s.units_per_day) END AS units_left,
    CASE WHEN s.units_total IS NULL THEN NULL
         WHEN s.take_time IS NOT NULL
         THEN CURRENT_DATE + (CEIL(GREATEST(0, s.units_total - COALESCE(d.taken, 0) * s.units_per_day) / s.units_per_day)::int
                              - CASE WHEN COALESCE(d.taken_today, false) THEN 0 ELSE 1 END)
         ELSE s.started_on + s.paused_days + CEIL(s.units_total / s.units_per_day)::int END AS runs_out_on
  FROM supplies s
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE status = 'taken' AND dose_date >= s.started_on) AS taken,
           bool_or(status = 'taken' AND dose_date = CURRENT_DATE)                  AS taken_today
    FROM supply_doses WHERE supply_id = s.id) d ON true
) x;

-- Acha o item pelo nome; se nao achar e a pessoa so tem um item ativo, usa esse.
CREATE OR REPLACE FUNCTION f_find_supply(p_user bigint, p_item text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  IF COALESCE(trim(p_item), '') <> '' THEN
    SELECT id INTO v_id FROM supplies
    WHERE user_id = p_user AND status = 'active'
      AND (item ILIKE '%' || p_item || '%' OR p_item ILIKE '%' || item || '%')
    ORDER BY created_at DESC LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;
  IF (SELECT count(*) FROM supplies WHERE user_id = p_user AND status = 'active') = 1 THEN
    SELECT id INTO v_id FROM supplies WHERE user_id = p_user AND status = 'active';
    RETURN v_id;
  END IF;
  RETURN NULL;
END $$;

-- Cria ou atualiza o item. Quantidade (p_total) e restante agora (p_left) sao opcionais.
DROP FUNCTION IF EXISTS f_create_supply(bigint, text, integer, numeric, date, integer, text, time);
CREATE OR REPLACE FUNCTION f_create_supply(p_user bigint, p_item text, p_total integer DEFAULT NULL,
  p_per_day numeric DEFAULT 1, p_started date DEFAULT NULL, p_alert_days integer DEFAULT NULL,
  p_kind text DEFAULT NULL, p_take_time time DEFAULT NULL, p_left integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint; v_alert integer; v_kind text := CASE WHEN p_kind = 'remedio' THEN 'remedio' ELSE 'suplemento' END;
        v_row supplies_status%ROWTYPE; v_cur supplies_status%ROWTYPE; v_created boolean := false;
BEGIN
  SELECT supply_alert_days INTO v_alert FROM users WHERE id = p_user;
  v_alert := COALESCE(p_alert_days, CASE WHEN v_kind = 'remedio' THEN 7 END, v_alert, 5);
  v_id := f_find_supply(p_user, p_item);
  IF v_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM supplies WHERE id = v_id AND (item ILIKE '%' || p_item || '%' OR p_item ILIKE '%' || item || '%')) THEN
    -- caiu no "so existe um item": so reaproveita se o pedido nao traz nome proprio de outro item
    IF COALESCE(trim(p_item), '') NOT IN ('', 'comprimido', 'remedio', 'pilula', 'capsula') THEN v_id := NULL; END IF;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO supplies(user_id, item, units_total, pack_size, units_per_day, started_on, alert_days, kind, take_time)
    VALUES (p_user, p_item, COALESCE(p_left, p_total), COALESCE(p_total, p_left), COALESCE(p_per_day, 1),
            COALESCE(p_started, CURRENT_DATE), v_alert, v_kind, p_take_time) RETURNING id INTO v_id;
    v_created := true;
  ELSE
    SELECT * INTO v_cur FROM supplies_status WHERE id = v_id;
    IF p_left IS NOT NULL OR p_total IS NOT NULL THEN
      UPDATE supplies SET units_total = COALESCE(p_left, p_total), pack_size = COALESCE(p_total, p_left, pack_size),
        started_on = COALESCE(p_started, CURRENT_DATE), paused_days = 0, alert_notified_on = NULL WHERE id = v_id;
    ELSIF p_take_time IS NOT NULL AND v_cur.take_time IS NULL AND v_cur.units_left IS NOT NULL THEN
      -- ligou o lembrete de tomar: passa a contar a partir do que resta hoje
      UPDATE supplies SET units_total = GREATEST(1, round(v_cur.units_left)::int), started_on = CURRENT_DATE, paused_days = 0 WHERE id = v_id;
    END IF;
    UPDATE supplies SET units_per_day = COALESCE(p_per_day, units_per_day), alert_days = COALESCE(p_alert_days, alert_days),
      kind = CASE WHEN p_kind IS NOT NULL THEN v_kind ELSE kind END, take_time = COALESCE(p_take_time, take_time) WHERE id = v_id;
  END IF;
  SELECT * INTO v_row FROM supplies_status WHERE id = v_id;
  RETURN jsonb_build_object('id', v_id, 'item', v_row.item, 'created', v_created, 'kind', v_row.kind,
    'units_left', v_row.units_left, 'needs_total', v_row.units_left IS NULL,
    'take_time', to_char(v_row.take_time, 'HH24:MI'),
    'runs_out_on', to_char(v_row.runs_out_on, 'DD/MM'), 'alert_on', to_char(v_row.alert_on, 'DD/MM'), 'alert_days', v_row.alert_days);
END $$;

-- "Me lembre de tomar X as 11h": cria o item se ainda nao existe.
DROP FUNCTION IF EXISTS f_supply_schedule(bigint, text, text, boolean);
CREATE OR REPLACE FUNCTION f_supply_schedule(p_user bigint, p_item text, p_time text, p_clear boolean DEFAULT false, p_kind text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint; s supplies_status%ROWTYPE; r jsonb;
BEGIN
  v_id := f_find_supply(p_user, p_item);
  IF p_clear THEN
    IF v_id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;
    SELECT * INTO s FROM supplies_status WHERE id = v_id;
    UPDATE supplies SET take_time = NULL, units_total = CASE WHEN s.units_left IS NULL THEN NULL ELSE GREATEST(1, round(s.units_left)::int) END,
      started_on = CURRENT_DATE, paused_days = 0 WHERE id = v_id;
    UPDATE notifications SET state = 'cancelled' WHERE state = 'pending' AND supply_id = v_id AND type = 'dose';
    RETURN jsonb_build_object('found', true, 'item', s.item, 'cleared', true);
  END IF;
  r := f_create_supply(p_user, p_item, NULL, 1, NULL, NULL, p_kind, p_time::time, NULL);
  RETURN r || jsonb_build_object('found', true, 'cleared', false);
END $$;

-- Ajuste, compra e "tomei" tambem aceitam um nome vago quando so existe um item.
CREATE OR REPLACE FUNCTION f_supply_taken(p_user bigint, p_item text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint; s supplies%ROWTYPE; v_row supplies_status%ROWTYPE;
BEGIN
  v_id := f_find_supply(p_user, p_item);
  IF v_id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT * INTO s FROM supplies WHERE id = v_id;
  IF s.take_time IS NULL THEN RETURN jsonb_build_object('found', true, 'tracking', false, 'item', s.item); END IF;
  INSERT INTO supply_doses(supply_id, user_id, dose_date, status, taken_at)
  VALUES (s.id, p_user, CURRENT_DATE, 'taken', now())
  ON CONFLICT (supply_id, dose_date) DO UPDATE SET status = 'taken', taken_at = now() WHERE supply_doses.status <> 'taken';
  UPDATE notifications SET state = 'cancelled'
  WHERE state = 'pending' AND dose_id IN (SELECT id FROM supply_doses WHERE supply_id = s.id AND dose_date = CURRENT_DATE);
  SELECT * INTO v_row FROM supplies_status WHERE id = s.id;
  RETURN jsonb_build_object('found', true, 'tracking', true, 'item', v_row.item, 'units_left', v_row.units_left,
    'runs_out_on', to_char(v_row.runs_out_on, 'DD/MM'));
END $$;

CREATE OR REPLACE FUNCTION f_supply_bought(p_user bigint, p_item text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint; s supplies%ROWTYPE;
BEGIN
  v_id := f_find_supply(p_user, p_item);
  IF v_id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT * INTO s FROM supplies WHERE id = v_id;
  UPDATE supplies SET units_total = COALESCE(pack_size, units_total), started_on = CURRENT_DATE, paused_days = 0, alert_notified_on = NULL WHERE id = v_id;
  RETURN jsonb_build_object('found', true, 'item', s.item, 'units_total', COALESCE(s.pack_size, s.units_total));
END $$;

CREATE OR REPLACE FUNCTION f_supply_adjust(p_user bigint, p_item text, p_units_left integer, p_pause_days integer)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  v_id := f_find_supply(p_user, p_item);
  IF v_id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;
  IF p_units_left IS NOT NULL THEN
    UPDATE supplies SET units_total = p_units_left, pack_size = COALESCE(pack_size, p_units_left),
      started_on = CURRENT_DATE, paused_days = 0, alert_notified_on = NULL WHERE id = v_id;
  END IF;
  IF COALESCE(p_pause_days, 0) > 0 THEN
    UPDATE supplies SET paused_days = paused_days + p_pause_days, alert_notified_on = NULL WHERE id = v_id;
  END IF;
  RETURN (SELECT jsonb_build_object('found', true, 'item', item, 'units_left', units_left,
            'runs_out_on', to_char(runs_out_on, 'DD/MM'), 'alert_on', to_char(alert_on, 'DD/MM'))
          FROM supplies_status WHERE id = v_id);
END $$;

DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'agente' LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = agente, public', f.sig);
  END LOOP;
END $$;

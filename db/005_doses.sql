-- Lembrete de tomar (doses), tipo do item (remedio/suplemento) e aviso de compra no resumo.
SET search_path = agente;

ALTER TABLE supplies ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'suplemento' CHECK (kind IN ('suplemento','remedio'));
ALTER TABLE supplies ADD COLUMN IF NOT EXISTS take_time time;       -- horario do lembrete diario; NULL = sem lembrete
ALTER TABLE supplies ADD COLUMN IF NOT EXISTS pack_size integer;    -- tamanho da embalagem, usado por "comprei"
UPDATE supplies SET pack_size = units_total WHERE pack_size IS NULL;

CREATE TABLE IF NOT EXISTS supply_doses (
  id         bigserial PRIMARY KEY,
  supply_id  bigint      NOT NULL REFERENCES supplies(id) ON DELETE CASCADE,
  user_id    bigint      NOT NULL REFERENCES users(id),
  dose_date  date        NOT NULL,
  status     text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','taken','skipped','missed')),
  taken_at   timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (supply_id, dose_date)
);

ALTER TABLE notifications ADD COLUMN IF NOT EXISTS dose_id bigint REFERENCES supply_doses(id) ON DELETE CASCADE;
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check CHECK (type IN ('reminder','pre_alert','repeat','supply','dose'));

-- Estoque: com lembrete de tomar, so as doses marcadas como tomadas descontam; sem ele, calcula por dias.
DROP VIEW IF EXISTS supplies_status;
CREATE VIEW supplies_status AS
SELECT x.*, x.runs_out_on - x.alert_days AS alert_on
FROM (
  SELECT s.*,
    CASE WHEN s.take_time IS NOT NULL
         THEN GREATEST(0, s.units_total - COALESCE(d.taken, 0) * s.units_per_day)
         ELSE GREATEST(0, s.units_total - ((CURRENT_DATE - s.started_on) - s.paused_days) * s.units_per_day) END AS units_left,
    CASE WHEN s.take_time IS NOT NULL
         THEN CURRENT_DATE + (CEIL(GREATEST(0, s.units_total - COALESCE(d.taken, 0) * s.units_per_day) / s.units_per_day)::int
                              - CASE WHEN COALESCE(d.taken_today, false) THEN 0 ELSE 1 END)
         ELSE s.started_on + s.paused_days + CEIL(s.units_total / s.units_per_day)::int END AS runs_out_on
  FROM supplies s
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE status = 'taken' AND dose_date >= s.started_on) AS taken,
           bool_or(status = 'taken' AND dose_date = CURRENT_DATE)                  AS taken_today
    FROM supply_doses WHERE supply_id = s.id) d ON true
) x;

-- Cria a dose do dia (e o primeiro aviso) quando chega o horario; doses de dias anteriores viram "esquecida".
CREATE OR REPLACE FUNCTION f_enqueue_doses() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE notifications SET state = 'cancelled'
  WHERE state = 'pending' AND dose_id IN (
    SELECT d.id FROM supply_doses d JOIN users u ON u.id = d.user_id
    WHERE d.status = 'pending' AND d.dose_date < (now() AT TIME ZONE u.timezone)::date);
  UPDATE supply_doses d SET status = 'missed' FROM users u
  WHERE u.id = d.user_id AND d.status = 'pending' AND d.dose_date < (now() AT TIME ZONE u.timezone)::date;

  WITH due AS (
    SELECT s.id AS sid, s.user_id, (now() AT TIME ZONE u.timezone)::date AS d
    FROM supplies s JOIN users u ON u.id = s.user_id
    WHERE s.status = 'active' AND s.take_time IS NOT NULL
      AND (now() AT TIME ZONE u.timezone)::time >= s.take_time
      AND (now() AT TIME ZONE u.timezone)::time <  time '23:30'
      AND NOT EXISTS (SELECT 1 FROM supply_doses x WHERE x.supply_id = s.id AND x.dose_date = (now() AT TIME ZONE u.timezone)::date)),
  ins AS (
    INSERT INTO supply_doses(supply_id, user_id, dose_date) SELECT sid, user_id, d FROM due RETURNING id, supply_id, user_id)
  INSERT INTO notifications(user_id, supply_id, dose_id, type, fire_at) SELECT user_id, supply_id, id, 'dose', now() FROM ins;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Fila de envios: lembretes (repete em 15 min) e doses (repete a cada 10 min ate marcar, ate 23:30).
-- O aviso de compra do estoque agora vai no resumo da manha, nao mais como mensagem avulsa.
CREATE OR REPLACE FUNCTION f_claim_due() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  PERFORM f_enqueue_doses();
  WITH claimed AS (
    UPDATE notifications n SET state = 'sent', sent_at = now()
    WHERE n.id IN (
      SELECT x.id FROM notifications x
      WHERE x.state = 'pending' AND x.fire_at <= now()
        AND (x.reminder_id IS NULL OR EXISTS (SELECT 1 FROM reminders r WHERE r.id = x.reminder_id AND r.status = 'pending'))
        AND (x.dose_id IS NULL OR EXISTS (SELECT 1 FROM supply_doses dd WHERE dd.id = x.dose_id AND dd.status = 'pending'))
      ORDER BY x.fire_at LIMIT 20 FOR UPDATE SKIP LOCKED)
    RETURNING n.*),
  rep AS (
    INSERT INTO notifications(user_id, reminder_id, type, fire_at)
    SELECT user_id, reminder_id, 'repeat', now() + interval '15 minutes' FROM claimed WHERE type = 'reminder'
    RETURNING 1),
  repd AS (
    INSERT INTO notifications(user_id, supply_id, dose_id, type, fire_at)
    SELECT c.user_id, c.supply_id, c.dose_id, 'dose', now() + interval '10 minutes'
    FROM claimed c JOIN users u ON u.id = c.user_id
    WHERE c.type = 'dose' AND (now() AT TIME ZONE u.timezone)::time < time '23:30'
    RETURNING 1)
  SELECT jsonb_agg(jsonb_build_object(
      'notification_id', c.id, 'type', c.type, 'chat_id', u.telegram_id, 'user_name', u.name,
      'reminder_id', c.reminder_id, 'title', r.title,
      'due', to_char(r.due_at AT TIME ZONE u.timezone, 'DD/MM HH24:MI'),
      'offset_minutes', c.offset_minutes, 'supply_id', c.supply_id, 'dose_id', c.dose_id, 'item', s.item,
      'days_left', (s.runs_out_on - CURRENT_DATE)))
  INTO v
  FROM claimed c JOIN users u ON u.id = c.user_id
  LEFT JOIN reminders r ON r.id = c.reminder_id
  LEFT JOIN supplies_status s ON s.id = c.supply_id;
  RETURN v;
END $$;

-- Botoes: acrescenta took (tomei) e skipd (pular hoje); "comprei" volta ao tamanho da embalagem.
CREATE OR REPLACE FUNCTION f_callback(p_user bigint, p_data text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint := NULLIF(split_part(p_data, ':', 2), '')::bigint;
        r reminders%ROWTYPE; s supplies%ROWTYPE; tz text; v_new timestamptz; v_sid bigint; v_st supplies_status%ROWTYPE;
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  IF a = 'sum' THEN
    UPDATE users SET summary_time = substr(p_data, 5)::time, onboarding_step = 'done', onboarded_at = COALESCE(onboarded_at, now())
    WHERE id = p_user;
    RETURN jsonb_build_object('text', 'Pronto! Seu resumo diario sai as ' || substr(p_data, 5) ||
      '. Pode me mandar seu primeiro lembrete, por texto ou audio.', 'kb', 'none');
  ELSIF a = 'lead' THEN
    RETURN f_set_lead(p_user, v_id, split_part(p_data, ':', 3)::integer);
  ELSIF a IN ('took', 'skipd') THEN
    UPDATE supply_doses SET status = CASE WHEN a = 'took' THEN 'taken' ELSE 'skipped' END,
                            taken_at = CASE WHEN a = 'took' THEN now() END
    WHERE id = v_id AND user_id = p_user AND status = 'pending' RETURNING supply_id INTO v_sid;
    IF v_sid IS NULL THEN RETURN jsonb_build_object('text', 'Essa dose ja foi registrada.', 'kb', 'none'); END IF;
    UPDATE notifications SET state = 'cancelled' WHERE dose_id = v_id AND state = 'pending';
    SELECT * INTO v_st FROM supplies_status WHERE id = v_sid;
    IF a = 'took' THEN
      RETURN jsonb_build_object('text', 'Anotado: tomou ' || v_st.item || '. Restam ' || round(v_st.units_left)::int ||
        ' (acaba em ' || to_char(v_st.runs_out_on, 'DD/MM') || ').', 'kb', 'none');
    END IF;
    RETURN jsonb_build_object('text', 'Ok, pulei a dose de hoje de ' || v_st.item || '.', 'kb', 'none');
  ELSIF a IN ('bought', 'later') THEN
    SELECT * INTO s FROM supplies WHERE id = v_id AND user_id = p_user;
    IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Nao encontrei esse item.', 'kb', 'none'); END IF;
    IF a = 'bought' THEN
      UPDATE supplies SET units_total = COALESCE(pack_size, units_total), started_on = CURRENT_DATE, paused_days = 0, alert_notified_on = NULL WHERE id = v_id;
      RETURN jsonb_build_object('text', 'Anotado! Recomecei a contagem de ' || s.item || ': ' || COALESCE(s.pack_size, s.units_total) || ' unidades.', 'kb', 'none');
    ELSE
      RETURN jsonb_build_object('text', 'Combinado, vou lembrar no proximo resumo.', 'kb', 'none');
    END IF;
  END IF;

  SELECT * INTO r FROM reminders WHERE id = v_id AND user_id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Nao encontrei esse lembrete.', 'kb', 'none'); END IF;
  IF a = 'done' THEN
    UPDATE reminders SET status = 'done' WHERE id = v_id;
    UPDATE notifications SET state = 'cancelled' WHERE reminder_id = v_id AND state = 'pending';
    RETURN jsonb_build_object('text', 'Feito: ' || r.title, 'kb', 'none');
  ELSIF a = 'snz1h' THEN
    UPDATE notifications SET state = 'cancelled' WHERE reminder_id = v_id AND state = 'pending';
    INSERT INTO notifications(user_id, reminder_id, type, fire_at) VALUES (p_user, v_id, 'reminder', now() + interval '1 hour');
    RETURN jsonb_build_object('text', 'Adiado em 1 hora: ' || r.title, 'kb', 'none');
  ELSIF a = 'snzt' THEN
    RETURN jsonb_build_object('text', 'Adiar "' || r.title || '" para amanha. No mesmo horario ou em outro?', 'kb', 'snooze', 'rid', v_id);
  ELSIF a = 'snzs' THEN
    v_new := ((CURRENT_DATE + 1) + ((COALESCE(r.due_at, now()) AT TIME ZONE tz)::time)) AT TIME ZONE tz;
    RETURN f_provide_time(p_user, v_id, v_new);
  ELSIF a = 'snzo' THEN
    RETURN jsonb_build_object('text', 'Para que dia e horario? (ex.: amanha 15h)', 'kb', 'none',
      'state', jsonb_build_object('kind', 'snooze', 'reminder_id', v_id)::text);
  END IF;
  RETURN jsonb_build_object('text', 'Nao entendi esse botao.', 'kb', 'none');
END $$;

-- Cria/atualiza item: tipo (remedio avisa 7 dias antes, suplemento usa a preferencia) e horario de tomar.
DROP FUNCTION IF EXISTS f_create_supply(bigint, text, integer, numeric, date, integer);
CREATE OR REPLACE FUNCTION f_create_supply(p_user bigint, p_item text, p_total integer,
  p_per_day numeric DEFAULT 1, p_started date DEFAULT CURRENT_DATE, p_alert_days integer DEFAULT NULL,
  p_kind text DEFAULT NULL, p_take_time time DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint; v_alert integer; v_kind text := CASE WHEN p_kind = 'remedio' THEN 'remedio' ELSE 'suplemento' END; v_row supplies_status%ROWTYPE;
BEGIN
  SELECT supply_alert_days INTO v_alert FROM users WHERE id = p_user;
  v_alert := COALESCE(p_alert_days, CASE WHEN v_kind = 'remedio' THEN 7 END, v_alert, 5);
  SELECT id INTO v_id FROM supplies WHERE user_id = p_user AND lower(item) = lower(p_item) AND status = 'active' LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO supplies(user_id, item, units_total, pack_size, units_per_day, started_on, alert_days, kind, take_time)
    VALUES (p_user, p_item, p_total, p_total, COALESCE(p_per_day, 1), COALESCE(p_started, CURRENT_DATE), v_alert, v_kind, p_take_time) RETURNING id INTO v_id;
  ELSE
    UPDATE supplies SET units_total = p_total, pack_size = p_total, units_per_day = COALESCE(p_per_day, 1),
      started_on = COALESCE(p_started, CURRENT_DATE), paused_days = 0, alert_days = v_alert, alert_notified_on = NULL,
      kind = v_kind, take_time = COALESCE(p_take_time, take_time)
    WHERE id = v_id;
  END IF;
  SELECT * INTO v_row FROM supplies_status WHERE id = v_id;
  RETURN jsonb_build_object('id', v_id, 'item', v_row.item, 'units_left', v_row.units_left, 'kind', v_row.kind,
    'take_time', to_char(v_row.take_time, 'HH24:MI'),
    'runs_out_on', to_char(v_row.runs_out_on, 'DD/MM'), 'alert_on', to_char(v_row.alert_on, 'DD/MM'), 'alert_days', v_row.alert_days);
END $$;

-- "Tomei a vitamina D" por texto: marca a dose de hoje.
CREATE OR REPLACE FUNCTION f_supply_taken(p_user bigint, p_item text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s supplies%ROWTYPE; v_dose bigint; v_row supplies_status%ROWTYPE;
BEGIN
  SELECT * INTO s FROM supplies WHERE user_id = p_user AND status = 'active' AND item ILIKE '%' || p_item || '%'
  ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  IF s.take_time IS NULL THEN RETURN jsonb_build_object('found', true, 'tracking', false, 'item', s.item); END IF;
  INSERT INTO supply_doses(supply_id, user_id, dose_date, status, taken_at)
  VALUES (s.id, p_user, CURRENT_DATE, 'taken', now())
  ON CONFLICT (supply_id, dose_date) DO UPDATE SET status = 'taken', taken_at = now() WHERE supply_doses.status <> 'taken'
  RETURNING id INTO v_dose;
  UPDATE notifications SET state = 'cancelled'
  WHERE state = 'pending' AND dose_id IN (SELECT id FROM supply_doses WHERE supply_id = s.id AND dose_date = CURRENT_DATE);
  SELECT * INTO v_row FROM supplies_status WHERE id = s.id;
  RETURN jsonb_build_object('found', true, 'tracking', true, 'item', v_row.item, 'units_left', v_row.units_left,
    'runs_out_on', to_char(v_row.runs_out_on, 'DD/MM'));
END $$;

-- Liga, muda ou desliga o lembrete diario de tomar. Ao ligar, o que resta hoje passa a ser o total contado.
CREATE OR REPLACE FUNCTION f_supply_schedule(p_user bigint, p_item text, p_time text, p_clear boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s supplies_status%ROWTYPE;
BEGIN
  SELECT * INTO s FROM supplies_status WHERE user_id = p_user AND status = 'active' AND item ILIKE '%' || p_item || '%'
  ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  IF p_clear THEN
    UPDATE supplies SET take_time = NULL, units_total = GREATEST(1, round(s.units_left)::int), started_on = CURRENT_DATE, paused_days = 0 WHERE id = s.id;
    UPDATE notifications SET state = 'cancelled' WHERE state = 'pending' AND supply_id = s.id AND type = 'dose';
    RETURN jsonb_build_object('found', true, 'item', s.item, 'cleared', true);
  END IF;
  IF s.take_time IS NULL THEN
    UPDATE supplies SET take_time = p_time::time, units_total = GREATEST(1, round(s.units_left)::int), started_on = CURRENT_DATE, paused_days = 0 WHERE id = s.id;
  ELSE
    UPDATE supplies SET take_time = p_time::time WHERE id = s.id;
  END IF;
  RETURN jsonb_build_object('found', true, 'item', s.item, 'cleared', false, 'take_time', to_char(p_time::time, 'HH24:MI'));
END $$;

-- "Comprei" por texto volta ao tamanho da embalagem.
CREATE OR REPLACE FUNCTION f_supply_bought(p_user bigint, p_item text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s supplies%ROWTYPE;
BEGIN
  SELECT * INTO s FROM supplies WHERE user_id = p_user AND status = 'active' AND item ILIKE '%' || p_item || '%'
  ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  UPDATE supplies SET units_total = COALESCE(pack_size, units_total), started_on = CURRENT_DATE, paused_days = 0, alert_notified_on = NULL WHERE id = s.id;
  RETURN jsonb_build_object('found', true, 'item', s.item, 'units_total', COALESCE(s.pack_size, s.units_total));
END $$;

-- Funcoes recriadas perdem o search_path: reaplica em todas.
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'agente' LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = agente, public', f.sig);
  END LOOP;
END $$;

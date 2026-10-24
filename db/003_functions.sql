-- Regras de negocio do agente em funcoes SQL. O n8n so orquestra e formata.
SET search_path = agente;

ALTER DATABASE "AgenteTelegram" SET timezone TO 'America/Sao_Paulo';

-- Cria lembrete ou compromisso (kind=event) e seus avisos. p_shared cria para todos.
CREATE OR REPLACE FUNCTION f_create_reminder(
  p_user bigint, p_title text, p_due timestamptz, p_shared boolean DEFAULT false,
  p_lead integer DEFAULT NULL, p_kind text DEFAULT 'reminder', p_event_id text DEFAULT NULL,
  p_source text DEFAULT 'text') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r record; v_rid bigint; v_my bigint; v_lead integer; v_ask boolean := false;
        v_group uuid := CASE WHEN p_shared THEN gen_random_uuid() END;
BEGIN
  FOR r IN SELECT id, default_lead_minutes FROM users WHERE id = p_user OR p_shared LOOP
    INSERT INTO reminders(user_id, kind, title, due_at, status, calendar_event_id, shared_group, source)
    VALUES (r.id, p_kind, p_title, p_due, 'pending',
            CASE WHEN r.id = p_user THEN p_event_id END, v_group, p_source)
    RETURNING id INTO v_rid;
    IF r.id = p_user THEN v_my := v_rid; END IF;
    IF p_kind = 'reminder' THEN
      INSERT INTO notifications(user_id, reminder_id, type, fire_at) VALUES (r.id, v_rid, 'reminder', p_due);
    END IF;
    v_lead := COALESCE(CASE WHEN r.id = p_user THEN p_lead END, r.default_lead_minutes);
    IF v_lead IS NOT NULL AND v_lead > 0 AND p_due - make_interval(mins => v_lead) > now() THEN
      INSERT INTO notifications(user_id, reminder_id, type, fire_at, offset_minutes)
      VALUES (r.id, v_rid, 'pre_alert', p_due - make_interval(mins => v_lead), v_lead);
    END IF;
    IF r.id = p_user AND p_lead IS NULL AND r.default_lead_minutes IS NULL THEN v_ask := true; END IF;
  END LOOP;
  RETURN jsonb_build_object('reminder_id', v_my, 'ask_lead', v_ask, 'title', p_title, 'due_at', p_due);
END $$;

-- Aviso antes (botoes "15 min / 1h / 1 dia"). 0 = nao avisar.
CREATE OR REPLACE FUNCTION f_set_lead(p_user bigint, p_rid bigint, p_minutes integer)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r reminders%ROWTYPE;
BEGIN
  SELECT * INTO r FROM reminders WHERE id = p_rid AND user_id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Nao encontrei esse lembrete.', 'kb', 'none'); END IF;
  IF p_minutes <= 0 THEN
    RETURN jsonb_build_object('text', 'Ok, sem aviso antes.', 'kb', 'none');
  END IF;
  IF r.due_at - make_interval(mins => p_minutes) <= now() THEN
    RETURN jsonb_build_object('text', 'Esse aviso ja passou do horario. Escolha uma antecedencia menor.', 'kb', 'lead', 'rid', p_rid);
  END IF;
  INSERT INTO notifications(user_id, reminder_id, type, fire_at, offset_minutes)
  VALUES (p_user, p_rid, 'pre_alert', r.due_at - make_interval(mins => p_minutes), p_minutes);
  RETURN jsonb_build_object('text', 'Fechado. Aviso ' ||
    CASE WHEN p_minutes >= 1440 THEN (p_minutes / 1440) || ' dia(s)' WHEN p_minutes >= 60 THEN (p_minutes / 60) || 'h' ELSE p_minutes || ' min' END
    || ' antes de "' || r.title || '".', 'kb', 'none');
END $$;

-- Reagenda um lembrete para um novo horario (adiar com horario escolhido).
CREATE OR REPLACE FUNCTION f_provide_time(p_user bigint, p_rid bigint, p_due timestamptz)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r reminders%ROWTYPE; tz text;
BEGIN
  SELECT * INTO r FROM reminders WHERE id = p_rid AND user_id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Nao encontrei esse lembrete.', 'kb', 'none'); END IF;
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  UPDATE notifications SET state = 'cancelled' WHERE reminder_id = p_rid AND state = 'pending';
  UPDATE reminders SET due_at = p_due, status = 'pending' WHERE id = p_rid;
  INSERT INTO notifications(user_id, reminder_id, type, fire_at) VALUES (p_user, p_rid, 'reminder', p_due);
  RETURN jsonb_build_object('text', 'Adiado: "' || r.title || '" para ' ||
    to_char(p_due AT TIME ZONE tz, 'DD/MM "as" HH24:MI') || '.', 'kb', 'none');
END $$;

-- Botoes: done, snz1h, snzt, snzs, snzo, lead:ID:MIN, bought, later, sum:HH:MM.
CREATE OR REPLACE FUNCTION f_callback(p_user bigint, p_data text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint := NULLIF(split_part(p_data, ':', 2), '')::bigint;
        r reminders%ROWTYPE; s supplies%ROWTYPE; tz text; v_new timestamptz;
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  IF a = 'sum' THEN
    UPDATE users SET summary_time = substr(p_data, 5)::time, onboarding_step = 'done', onboarded_at = COALESCE(onboarded_at, now())
    WHERE id = p_user;
    RETURN jsonb_build_object('text', 'Pronto! Seu resumo diario sai as ' || substr(p_data, 5) ||
      '. Pode me mandar seu primeiro lembrete, por texto ou audio.', 'kb', 'none');
  ELSIF a = 'lead' THEN
    RETURN f_set_lead(p_user, v_id, split_part(p_data, ':', 3)::integer);
  ELSIF a IN ('bought', 'later') THEN
    SELECT * INTO s FROM supplies WHERE id = v_id AND user_id = p_user;
    IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Nao encontrei esse item.', 'kb', 'none'); END IF;
    IF a = 'bought' THEN
      UPDATE supplies SET started_on = CURRENT_DATE, paused_days = 0, alert_notified_on = NULL WHERE id = v_id;
      RETURN jsonb_build_object('text', 'Anotado! Recomecei a contagem de ' || s.item || ': ' || s.units_total || ' unidades.', 'kb', 'none');
    ELSE
      INSERT INTO notifications(user_id, supply_id, type, fire_at)
      VALUES (p_user, v_id, 'supply', ((CURRENT_DATE + 1) + time '09:00') AT TIME ZONE tz);
      RETURN jsonb_build_object('text', 'Combinado, te lembro amanha de comprar ' || s.item || '.', 'kb', 'none');
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

-- Estoque.
CREATE OR REPLACE FUNCTION f_create_supply(p_user bigint, p_item text, p_total integer,
  p_per_day numeric DEFAULT 1, p_started date DEFAULT CURRENT_DATE, p_alert_days integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint; v_alert integer; v_row supplies_status%ROWTYPE;
BEGIN
  SELECT supply_alert_days INTO v_alert FROM users WHERE id = p_user;
  v_alert := COALESCE(p_alert_days, v_alert, 5);
  SELECT id INTO v_id FROM supplies WHERE user_id = p_user AND lower(item) = lower(p_item) AND status = 'active' LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO supplies(user_id, item, units_total, units_per_day, started_on, alert_days)
    VALUES (p_user, p_item, p_total, COALESCE(p_per_day, 1), COALESCE(p_started, CURRENT_DATE), v_alert) RETURNING id INTO v_id;
  ELSE
    UPDATE supplies SET units_total = p_total, units_per_day = COALESCE(p_per_day, 1),
      started_on = COALESCE(p_started, CURRENT_DATE), paused_days = 0, alert_days = v_alert, alert_notified_on = NULL
    WHERE id = v_id;
  END IF;
  SELECT * INTO v_row FROM supplies_status WHERE id = v_id;
  RETURN jsonb_build_object('id', v_id, 'item', v_row.item, 'units_left', v_row.units_left,
    'runs_out_on', to_char(v_row.runs_out_on, 'DD/MM'), 'alert_on', to_char(v_row.alert_on, 'DD/MM'), 'alert_days', v_row.alert_days);
END $$;

CREATE OR REPLACE FUNCTION f_supply_bought(p_user bigint, p_item text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s supplies%ROWTYPE;
BEGIN
  SELECT * INTO s FROM supplies WHERE user_id = p_user AND status = 'active' AND item ILIKE '%' || p_item || '%'
  ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  UPDATE supplies SET started_on = CURRENT_DATE, paused_days = 0, alert_notified_on = NULL WHERE id = s.id;
  RETURN jsonb_build_object('found', true, 'item', s.item, 'units_total', s.units_total);
END $$;

CREATE OR REPLACE FUNCTION f_supply_adjust(p_user bigint, p_item text, p_units_left integer, p_pause_days integer)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s supplies%ROWTYPE;
BEGIN
  SELECT * INTO s FROM supplies WHERE user_id = p_user AND status = 'active' AND item ILIKE '%' || p_item || '%'
  ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  IF p_units_left IS NOT NULL THEN
    UPDATE supplies SET units_total = p_units_left, started_on = CURRENT_DATE, paused_days = 0, alert_notified_on = NULL WHERE id = s.id;
  END IF;
  IF COALESCE(p_pause_days, 0) > 0 THEN
    UPDATE supplies SET paused_days = paused_days + p_pause_days, alert_notified_on = NULL WHERE id = s.id;
  END IF;
  RETURN (SELECT jsonb_build_object('found', true, 'item', item, 'units_left', units_left,
            'runs_out_on', to_char(runs_out_on, 'DD/MM'), 'alert_on', to_char(alert_on, 'DD/MM'))
          FROM supplies_status WHERE id = s.id);
END $$;

-- Preferencias (/config em linguagem natural).
CREATE OR REPLACE FUNCTION f_set_pref(p_user bigint, p_lead integer, p_summary time, p_supply_days integer)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE users SET default_lead_minutes = COALESCE(p_lead, default_lead_minutes),
                   summary_time = COALESCE(p_summary, summary_time),
                   supply_alert_days = COALESCE(p_supply_days, supply_alert_days)
  WHERE id = p_user;
  RETURN (SELECT jsonb_build_object('lead', default_lead_minutes, 'summary', to_char(summary_time, 'HH24:MI'), 'supply_days', supply_alert_days)
          FROM users WHERE id = p_user);
END $$;

-- Itens do banco para agenda/resumo: lembretes pendentes no intervalo e estoque com aviso vencido.
CREATE OR REPLACE FUNCTION f_agenda_db(p_user bigint, p_from timestamptz, p_to timestamptz)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'reminders', COALESCE((SELECT jsonb_agg(jsonb_build_object('title', r.title, 'due', to_char(r.due_at AT TIME ZONE u.timezone, 'DD/MM HH24:MI')) ORDER BY r.due_at)
                           FROM reminders r JOIN users u ON u.id = r.user_id
                           WHERE r.user_id = p_user AND r.kind = 'reminder' AND r.status = 'pending'
                             AND r.due_at >= p_from AND r.due_at < p_to), '[]'::jsonb),
    'supplies',  COALESCE((SELECT jsonb_agg(jsonb_build_object('item', item, 'units_left', units_left, 'runs_out_on', to_char(runs_out_on, 'DD/MM')))
                           FROM supplies_status WHERE user_id = p_user AND status = 'active' AND alert_on <= p_to::date), '[]'::jsonb));
$$;

-- Fila de envios: pega o que venceu (uma vez so) e agenda a repeticao de 15 min dos lembretes.
CREATE OR REPLACE FUNCTION f_claim_due() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  PERFORM f_enqueue_supply_alerts();
  WITH claimed AS (
    UPDATE notifications n SET state = 'sent', sent_at = now()
    WHERE n.id IN (
      SELECT x.id FROM notifications x
      WHERE x.state = 'pending' AND x.fire_at <= now()
        AND (x.reminder_id IS NULL OR EXISTS (SELECT 1 FROM reminders r WHERE r.id = x.reminder_id AND r.status = 'pending'))
      ORDER BY x.fire_at LIMIT 20 FOR UPDATE SKIP LOCKED)
    RETURNING n.*),
  rep AS (
    INSERT INTO notifications(user_id, reminder_id, type, fire_at)
    SELECT user_id, reminder_id, 'repeat', now() + interval '15 minutes' FROM claimed WHERE type = 'reminder'
    RETURNING 1)
  SELECT jsonb_agg(jsonb_build_object(
      'notification_id', c.id, 'type', c.type, 'chat_id', u.telegram_id, 'user_name', u.name,
      'reminder_id', c.reminder_id, 'title', r.title,
      'due', to_char(r.due_at AT TIME ZONE u.timezone, 'DD/MM HH24:MI'),
      'offset_minutes', c.offset_minutes, 'supply_id', c.supply_id, 'item', s.item,
      'days_left', (s.runs_out_on - CURRENT_DATE)))
  INTO v
  FROM claimed c JOIN users u ON u.id = c.user_id
  LEFT JOIN reminders r ON r.id = c.reminder_id
  LEFT JOIN supplies_status s ON s.id = c.supply_id;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION f_enqueue_supply_alerts() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  WITH due AS (
    UPDATE supplies s SET alert_notified_on = CURRENT_DATE
    FROM supplies_status v WHERE v.id = s.id AND s.status = 'active' AND s.alert_notified_on IS NULL AND v.alert_on <= CURRENT_DATE
    RETURNING s.id, s.user_id)
  INSERT INTO notifications(user_id, supply_id, type, fire_at) SELECT user_id, id, 'supply', now() FROM due;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Usuarios cujo resumo diario deve sair agora (janela de 30 min, uma vez por dia).
CREATE OR REPLACE FUNCTION f_summary_candidates() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  WITH due AS (
    UPDATE users u SET last_summary_on = (now() AT TIME ZONE u.timezone)::date
    WHERE u.onboarding_step = 'done'
      AND u.last_summary_on IS DISTINCT FROM (now() AT TIME ZONE u.timezone)::date
      AND (now() AT TIME ZONE u.timezone)::time >= u.summary_time
      AND (now() AT TIME ZONE u.timezone)::time <  u.summary_time + interval '30 minutes'
    RETURNING u.id, u.telegram_id, u.name, u.timezone, u.calendar_key)
  SELECT jsonb_agg(jsonb_build_object('user_id', id, 'chat_id', telegram_id, 'name', name, 'timezone', timezone, 'calendar_key', calendar_key))
  INTO v FROM due;
  RETURN v;
END $$;

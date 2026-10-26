-- 009: resumo da manha reformulado + resumo do fim do dia
SET search_path = agente, public;

ALTER TABLE users ADD COLUMN IF NOT EXISTS evening_enabled boolean NOT NULL DEFAULT true;
ALTER TABLE users ADD COLUMN IF NOT EXISTS evening_time time NOT NULL DEFAULT '20:00';
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_evening_on date;

-- operadoras e telefone entram em Moradia (contas da casa)
UPDATE fin_categories SET keywords = ARRAY(SELECT DISTINCT unnest(keywords || ARRAY['claro','vivo','tim','telefone','celular']))
WHERE is_default AND kind = 'expense' AND name = 'Moradia';

-- quem recebe resumo agora: manha (horario da pessoa) e fim do dia (20h por padrao)
CREATE OR REPLACE FUNCTION f_summary_candidates() RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE v_m jsonb; v_e jsonb;
BEGIN
  WITH due AS (
    UPDATE users u SET last_summary_on = (now() AT TIME ZONE u.timezone)::date
    WHERE u.onboarding_step = 'done'
      AND u.last_summary_on IS DISTINCT FROM (now() AT TIME ZONE u.timezone)::date
      AND (now() AT TIME ZONE u.timezone)::time >= u.summary_time
      AND (now() AT TIME ZONE u.timezone)::time <  u.summary_time + interval '30 minutes'
    RETURNING u.id, u.telegram_id, u.name, u.timezone, u.calendar_key)
  SELECT jsonb_agg(jsonb_build_object('user_id', id, 'chat_id', telegram_id, 'name', name, 'timezone', timezone, 'calendar_key', calendar_key, 'kind', 'morning'))
  INTO v_m FROM due;
  WITH due AS (
    UPDATE users u SET last_evening_on = (now() AT TIME ZONE u.timezone)::date
    WHERE u.onboarding_step = 'done' AND u.evening_enabled
      AND u.last_evening_on IS DISTINCT FROM (now() AT TIME ZONE u.timezone)::date
      AND (now() AT TIME ZONE u.timezone)::time >= u.evening_time
      AND (now() AT TIME ZONE u.timezone)::time <  u.evening_time + interval '30 minutes'
    RETURNING u.id, u.telegram_id, u.name, u.timezone, u.calendar_key)
  SELECT jsonb_agg(jsonb_build_object('user_id', id, 'chat_id', telegram_id, 'name', name, 'timezone', timezone, 'calendar_key', calendar_key, 'kind', 'evening'))
  INTO v_e FROM due;
  RETURN coalesce(v_m, '[]'::jsonb) || coalesce(v_e, '[]'::jsonb);
END $$;

-- dados do resumo (so leitura). Lembretes ligados a contas ficam no bloco de contas, nao em "Lembretes".
CREATE OR REPLACE FUNCTION f_summary_data(p_user bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE
  tz text; today date; ps date; pe date; v jsonb;
  d0 timestamptz; d1 timestamptz; d2 timestamptz;
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  today := (now() AT TIME ZONE tz)::date;
  d0 := today::timestamp AT TIME ZONE tz; d1 := (today + 1)::timestamp AT TIME ZONE tz; d2 := (today + 2)::timestamp AT TIME ZONE tz;
  SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, 0);
  SELECT jsonb_build_object(
    'today_reminders', COALESCE((SELECT jsonb_agg(jsonb_build_object('time', to_char(r.due_at AT TIME ZONE tz, 'HH24:MI'), 'title', r.title) ORDER BY r.due_at)
        FROM reminders r WHERE r.user_id = p_user AND r.kind = 'reminder' AND r.status = 'pending' AND r.due_at >= d0 AND r.due_at < d1
          AND NOT EXISTS (SELECT 1 FROM fin_entries f WHERE f.reminder_id = r.id)), '[]'::jsonb),
    'overdue_today', COALESCE((SELECT jsonb_agg(jsonb_build_object('time', to_char(r.due_at AT TIME ZONE tz, 'HH24:MI'), 'title', r.title) ORDER BY r.due_at)
        FROM reminders r WHERE r.user_id = p_user AND r.kind = 'reminder' AND r.status = 'pending' AND r.due_at >= d0 AND r.due_at <= now()
          AND NOT EXISTS (SELECT 1 FROM fin_entries f WHERE f.reminder_id = r.id)), '[]'::jsonb),
    'tomorrow_reminders', COALESCE((SELECT jsonb_agg(jsonb_build_object('time', to_char(r.due_at AT TIME ZONE tz, 'HH24:MI'), 'title', r.title) ORDER BY r.due_at)
        FROM reminders r WHERE r.user_id = p_user AND r.kind = 'reminder' AND r.status = 'pending' AND r.due_at >= d1 AND r.due_at < d2
          AND NOT EXISTS (SELECT 1 FROM fin_entries f WHERE f.reminder_id = r.id)), '[]'::jsonb),
    'supplies', COALESCE((SELECT jsonb_agg(jsonb_build_object('item', item, 'units_left', units_left, 'runs_out_on', to_char(runs_out_on, 'DD/MM')))
        FROM supplies_status WHERE user_id = p_user AND status = 'active' AND alert_on <= today), '[]'::jsonb),
    'bills', COALESCE((SELECT jsonb_agg(jsonb_build_object('description', description, 'amount', amount, 'due', to_char(due_on, 'DD/MM'),
          'late', due_on < today, 'today', due_on = today, 'tomorrow', due_on = today + 1, 'kind', kind) ORDER BY due_on, id)
        FROM (SELECT * FROM fin_entries WHERE user_id = p_user AND status = 'pending' AND kind = 'expense' AND due_on <= today + 7 ORDER BY due_on, id LIMIT 8) b), '[]'::jsonb),
    'yesterday_spent', (SELECT sum(amount) FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on = today - 1),
    'budget_alerts', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', c.name, 'spent', s.sp, 'budget', c.budget, 'pct', round(s.sp / c.budget * 100)) ORDER BY s.sp / c.budget DESC)
        FROM fin_categories c CROSS JOIN LATERAL (SELECT f_fin_spent(p_user, c.id, ps, pe) AS sp) s
        WHERE c.user_id = p_user AND c.kind = 'expense' AND c.budget IS NOT NULL AND s.sp / c.budget >= 0.8), '[]'::jsonb)
  ) INTO v;
  RETURN v;
END $$;

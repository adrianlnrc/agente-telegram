-- Fase 2: limite geral do mes, metas de economia, planejamento e preferencias.
SET search_path TO agente, public;

ALTER TABLE users ADD COLUMN IF NOT EXISTS fin_total_limit numeric(12,2);
ALTER TABLE users ADD COLUMN IF NOT EXISTS fin_income numeric(12,2);
ALTER TABLE users ADD COLUMN IF NOT EXISTS nickname text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS no_emoji boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS morning_enabled boolean NOT NULL DEFAULT true;

CREATE TABLE IF NOT EXISTS fin_goals (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  norm_name  text NOT NULL,
  target     numeric(12,2) NOT NULL CHECK (target > 0),
  deadline   date,
  auto       boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fin_goals_user ON fin_goals (user_id);
CREATE TABLE IF NOT EXISTS fin_goal_deposits (
  id         bigserial PRIMARY KEY,
  goal_id    bigint NOT NULL REFERENCES fin_goals(id) ON DELETE CASCADE,
  amount     numeric(12,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- gastos pagos do mes financeiro (todas as categorias)
CREATE OR REPLACE FUNCTION f_fin_total_spent(p_user bigint, p_start date, p_end date) RETURNS numeric
LANGUAGE sql STABLE SET search_path = agente, public AS $$
  SELECT coalesce(sum(amount), 0) FROM fin_entries
  WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN p_start AND p_end
$$;

-- quanto ja foi guardado: depositos manuais + parte automatica (receitas pagas - gastos pagos desde a criacao, dividido entre as metas automaticas)
CREATE OR REPLACE FUNCTION f_fin_goal_saved(p_goal bigint) RETURNS numeric
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE g fin_goals%ROWTYPE; manual numeric; net numeric := 0; n integer;
BEGIN
  SELECT * INTO g FROM fin_goals WHERE id = p_goal;
  IF NOT FOUND THEN RETURN 0; END IF;
  SELECT coalesce(sum(amount), 0) INTO manual FROM fin_goal_deposits WHERE goal_id = p_goal;
  IF g.auto THEN
    SELECT count(*) INTO n FROM fin_goals WHERE user_id = g.user_id AND auto;
    SELECT greatest(0, coalesce(sum(CASE WHEN kind = 'income' THEN amount ELSE -amount END), 0)) INTO net
    FROM fin_entries WHERE user_id = g.user_id AND status = 'paid' AND occurred_on >= g.created_at::date AND occurred_on <= f_fin_today(g.user_id);
    manual := manual + round(net / greatest(n, 1), 2);
  END IF;
  RETURN greatest(manual, 0);
END $$;

CREATE OR REPLACE FUNCTION f_fin_goal_find(p_user bigint, p_name text) RETURNS bigint
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE q text := f_norm(coalesce(p_name, '')); v_id bigint; n integer;
BEGIN
  IF q <> '' THEN
    SELECT id INTO v_id FROM fin_goals WHERE user_id = p_user AND (norm_name LIKE '%' || q || '%' OR q LIKE '%' || norm_name || '%') ORDER BY id DESC LIMIT 1;
    RETURN v_id;
  END IF;
  SELECT count(*) INTO n FROM fin_goals WHERE user_id = p_user;
  IF n = 1 THEN SELECT id INTO v_id FROM fin_goals WHERE user_id = p_user; END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION f_fin_goal_line(p_goal bigint) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE g fin_goals%ROWTYPE; sv numeric; today date; m integer; falta numeric; t text;
BEGIN
  SELECT * INTO g FROM fin_goals WHERE id = p_goal;
  sv := f_fin_goal_saved(p_goal); falta := greatest(g.target - sv, 0);
  today := f_fin_today(g.user_id);
  t := g.name || ': ' || f_brl(sv) || ' de ' || f_brl(g.target) || ' (' || round(sv / g.target * 100) || '%)';
  IF falta = 0 THEN RETURN t || ', meta batida!'; END IF;
  t := t || ', faltam ' || f_brl(falta);
  IF g.deadline IS NOT NULL THEN
    IF g.deadline < today THEN RETURN t || ', o prazo (' || to_char(g.deadline, 'DD/MM/YYYY') || ') já passou'; END IF;
    m := greatest(1, (extract(year FROM g.deadline)::int - extract(year FROM today)::int) * 12 + extract(month FROM g.deadline)::int - extract(month FROM today)::int);
    t := t || ' até ' || to_char(g.deadline, 'DD/MM/YYYY') || ', cerca de ' || f_brl(ceil(falta / m)) || ' por mês';
  END IF;
  RETURN t || CASE WHEN g.auto THEN '' ELSE ' (só manual)' END;
END $$;

-- aviso do limite geral (80% e 100%), chamado junto com o aviso da categoria
CREATE OR REPLACE FUNCTION f_fin_limit_note(p_user bigint, p_added numeric, p_on date) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE lim numeric; ps date; pe date; after numeric; pa numeric; pb numeric;
BEGIN
  SELECT fin_total_limit INTO lim FROM users WHERE id = p_user;
  IF lim IS NULL THEN RETURN ''; END IF;
  SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, 0);
  IF p_on NOT BETWEEN ps AND pe THEN RETURN ''; END IF;
  after := f_fin_total_spent(p_user, ps, pe);
  pa := after / lim * 100; pb := (after - p_added) / lim * 100;
  IF pa >= 100 AND pb < 100 THEN
    RETURN E'\nAtenção: você passou o limite geral do mês: ' || f_brl(after) || ' de ' || f_brl(lim) || ' (' || round(pa) || '%).';
  ELSIF pa >= 80 AND pb < 80 THEN
    RETURN E'\nAtenção: você já usou ' || round(pa) || '% do limite geral do mês (' || f_brl(after) || ' de ' || f_brl(lim) || ').';
  END IF;
  RETURN '';
END $$;

-- aviso da categoria (corpo original) + limite geral
ALTER FUNCTION f_fin_budget_note(bigint, bigint, numeric, date) RENAME TO f_fin_cat_note;
CREATE OR REPLACE FUNCTION f_fin_budget_note(p_user bigint, p_cat bigint, p_added numeric, p_on date) RETURNS text
LANGUAGE sql STABLE SET search_path = agente, public AS $$
  SELECT f_fin_cat_note(p_user, p_cat, p_added, p_on) || f_fin_limit_note(p_user, p_added, p_on)
$$;

CREATE OR REPLACE FUNCTION f_fin_limit_text(p_user bigint) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE lim numeric; ps date; pe date; sp numeric; days integer;
BEGIN
  SELECT fin_total_limit INTO lim FROM users WHERE id = p_user;
  IF lim IS NULL THEN RETURN 'Você ainda não definiu um limite geral. Ex.: "quero gastar no máximo 3000 por mês".'; END IF;
  SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, 0);
  sp := f_fin_total_spent(p_user, ps, pe);
  days := greatest(pe - f_fin_today(p_user) + 1, 1);
  RETURN 'Limite geral ' || f_brl(lim) || ' (mês financeiro ' || to_char(ps, 'DD/MM') || ' a ' || to_char(pe, 'DD/MM') || '): gasto ' || f_brl(sp) || ' (' || round(sp / lim * 100) || '%). ' ||
    CASE WHEN lim > sp THEN 'Ainda pode gastar ' || f_brl(lim - sp) || ', cerca de ' || f_brl((lim - sp) / days) || ' por dia nos ' || days || ' dia(s) que restam.'
         ELSE 'Passou ' || f_brl(sp - lim) || ' do limite.' END;
END $$;

CREATE OR REPLACE FUNCTION f_fin_plan_text(p_user bigint) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE u users%ROWTYPE; ps date; pe date; today date := f_fin_today(p_user); inc numeric; sp numeric; com numeric; goals numeric := 0; sobra numeric; r record; m integer; falta numeric; t text; inc_src text;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user;
  SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, 0);
  IF u.fin_income IS NOT NULL THEN inc := u.fin_income; inc_src := 'renda prevista';
  ELSE SELECT coalesce(sum(amount), 0) INTO inc FROM fin_entries WHERE user_id = p_user AND kind = 'income' AND status = 'paid' AND occurred_on BETWEEN ps AND pe; inc_src := 'receitas recebidas'; END IF;
  SELECT coalesce(sum(amount), 0) INTO sp FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN ps AND least(today, pe);
  SELECT coalesce(sum(amount), 0) INTO com FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND
    ((status = 'pending' AND due_on <= pe) OR (status = 'paid' AND occurred_on > today AND occurred_on <= pe));
  FOR r IN SELECT * FROM fin_goals WHERE user_id = p_user AND deadline IS NOT NULL AND deadline >= today LOOP
    falta := greatest(r.target - f_fin_goal_saved(r.id), 0);
    m := greatest(1, (extract(year FROM r.deadline)::int - extract(year FROM today)::int) * 12 + extract(month FROM r.deadline)::int - extract(month FROM today)::int);
    goals := goals + ceil(falta / m);
  END LOOP;
  sobra := inc - sp - com - goals;
  t := 'Planejamento do mês (' || to_char(ps, 'DD/MM') || ' a ' || to_char(pe, 'DD/MM') || E'):\n- Renda (' || inc_src || '): ' || f_brl(inc) ||
       E'\n- Gasto até agora: ' || f_brl(sp) || E'\n- Já comprometido (contas a pagar e parcelas): ' || f_brl(com) ||
       E'\n- Metas pedem neste mês: ' || f_brl(goals) || E'\n= Sobra para gastar: ' || f_brl(sobra);
  IF u.fin_total_limit IS NOT NULL THEN
    t := t || E'\nLimite geral: ' || f_brl(u.fin_total_limit) || CASE WHEN sobra > u.fin_total_limit - sp - com THEN '; pelo limite, o teto de gasto restante é ' || f_brl(greatest(u.fin_total_limit - sp - com, 0)) ELSE '' END || '.';
  END IF;
  IF u.fin_income IS NULL THEN t := t || E'\nDefina a renda com "minha renda é 5000" para o cálculo ficar completo.'; END IF;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION f_fin_plan(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE
  act text := p->>'action'; v_amt numeric := round(nullif(p->>'budget_amount', '')::numeric, 2);
  v_name text := btrim(coalesce(p->>'title', '')); v_new text := btrim(coalesce(p->>'category', ''));
  v_dl date := f_safe_date(p->>'date'); v_mode text := lower(coalesce(p->>'keywords', ''));
  g fin_goals%ROWTYPE; v_id bigint; t text; r record; n integer := 0; na integer;
BEGIN
  IF act = 'limit_set' THEN
    IF v_amt IS NULL OR v_amt <= 0 THEN RETURN jsonb_build_object('text', 'Qual o valor do limite? Ex.: "quero gastar no máximo 3000 por mês".', 'kb', 'none'); END IF;
    UPDATE users SET fin_total_limit = v_amt WHERE id = p_user;
    RETURN jsonb_build_object('text', 'Limite geral do mês: ' || f_brl(v_amt) || '. Aviso quando chegar a 80% e a 100%. ' || f_fin_limit_text(p_user), 'kb', 'none');
  ELSIF act = 'limit_clear' THEN
    UPDATE users SET fin_total_limit = NULL WHERE id = p_user;
    RETURN jsonb_build_object('text', 'Tirei o limite geral. Os orçamentos por categoria continuam.', 'kb', 'none');
  ELSIF act = 'limit_status' THEN
    RETURN jsonb_build_object('text', f_fin_limit_text(p_user), 'kb', 'none');
  ELSIF act = 'income_set' THEN
    IF v_amt IS NULL OR v_amt <= 0 THEN RETURN jsonb_build_object('text', 'Qual a sua renda mensal? Ex.: "minha renda é 5000".', 'kb', 'none'); END IF;
    UPDATE users SET fin_income = v_amt WHERE id = p_user;
    RETURN jsonb_build_object('text', 'Anotei: renda prevista de ' || f_brl(v_amt) || ' por mês. Diga "meu planejamento" para ver a visão do mês.', 'kb', 'none');
  ELSIF act = 'plan_status' THEN
    RETURN jsonb_build_object('text', f_fin_plan_text(p_user), 'kb', 'none');
  ELSIF act = 'goal_create' THEN
    IF v_name = '' THEN RETURN jsonb_build_object('text', 'Qual o nome da meta? Ex.: "juntar 800 até dezembro pro presente de Natal".', 'kb', 'none'); END IF;
    IF v_amt IS NULL OR v_amt <= 0 THEN RETURN jsonb_build_object('text', 'Qual o valor da meta "' || v_name || '"?', 'kb', 'none'); END IF;
    IF v_dl IS NOT NULL AND v_dl < f_fin_today(p_user) THEN RETURN jsonb_build_object('text', 'Esse prazo já passou. Qual a data limite da meta?', 'kb', 'none'); END IF;
    INSERT INTO fin_goals (user_id, name, norm_name, target, deadline, auto) VALUES (p_user, initcap(left(v_name, 60)), f_norm(v_name), v_amt, v_dl, v_mode <> 'manual') RETURNING id INTO v_id;
    SELECT count(*) INTO na FROM fin_goals WHERE user_id = p_user AND auto;
    RETURN jsonb_build_object('text', 'Meta criada. ' || f_fin_goal_line(v_id) || '.' ||
      CASE WHEN v_mode = 'manual' THEN ' O progresso é só manual: diga "guardei 100 pra ' || lower(v_name) || '".'
           WHEN na > 1 THEN ' O que sobrar do mês (receitas menos gastos) é dividido igualmente entre as ' || na || ' metas automáticas; diga "essa meta é só manual" para tirar uma da divisão.'
           ELSE ' O progresso é automático (receitas menos gastos desde agora); você também pode dizer "guardei 100".' END, 'kb', 'none');
  ELSIF act IN ('goal_deposit', 'goal_withdraw') THEN
    IF v_amt IS NULL OR v_amt <= 0 THEN RETURN jsonb_build_object('text', 'Quanto? Ex.: "guardei 100 pro presente".', 'kb', 'none'); END IF;
    v_id := f_fin_goal_find(p_user, v_name);
    IF v_id IS NULL THEN RETURN jsonb_build_object('text', CASE WHEN v_name = '' THEN 'Para qual meta? Diga "minhas metas" para ver a lista.' ELSE 'Não achei a meta "' || v_name || '". Diga "minhas metas" para ver a lista.' END, 'kb', 'none'); END IF;
    INSERT INTO fin_goal_deposits (goal_id, amount) VALUES (v_id, CASE WHEN act = 'goal_deposit' THEN v_amt ELSE -v_amt END);
    RETURN jsonb_build_object('text', CASE WHEN act = 'goal_deposit' THEN 'Guardei ' ELSE 'Tirei ' END || f_brl(v_amt) || '. ' || f_fin_goal_line(v_id) || '.', 'kb', 'none');
  ELSIF act = 'goal_status' THEN
    IF v_name <> '' THEN
      v_id := f_fin_goal_find(p_user, v_name);
      IF v_id IS NULL THEN RETURN jsonb_build_object('text', 'Não achei a meta "' || v_name || '".', 'kb', 'none'); END IF;
      RETURN jsonb_build_object('text', f_fin_goal_line(v_id) || '.', 'kb', 'none');
    END IF;
    FOR r IN SELECT id FROM fin_goals WHERE user_id = p_user ORDER BY id LOOP n := n + 1; t := coalesce(t, '') || E'\n- ' || f_fin_goal_line(r.id); END LOOP;
    IF n = 0 THEN RETURN jsonb_build_object('text', 'Você ainda não tem metas. Ex.: "quero juntar 800 até dezembro pro presente de Natal".', 'kb', 'none'); END IF;
    RETURN jsonb_build_object('text', 'Suas metas:' || t, 'kb', 'none');
  ELSIF act = 'goal_edit' THEN
    v_id := f_fin_goal_find(p_user, v_name);
    IF v_id IS NULL THEN RETURN jsonb_build_object('text', 'Qual meta você quer mudar? Diga "minhas metas" para ver a lista.', 'kb', 'none'); END IF;
    UPDATE fin_goals SET target = coalesce(v_amt, target), deadline = coalesce(v_dl, deadline),
      name = CASE WHEN v_new <> '' THEN initcap(left(v_new, 60)) ELSE name END, norm_name = CASE WHEN v_new <> '' THEN f_norm(v_new) ELSE norm_name END,
      auto = CASE WHEN v_mode = 'manual' THEN false WHEN v_mode = 'auto' THEN true ELSE auto END WHERE id = v_id;
    RETURN jsonb_build_object('text', 'Atualizei. ' || f_fin_goal_line(v_id) || '.', 'kb', 'none');
  ELSIF act = 'goal_remove' THEN
    v_id := f_fin_goal_find(p_user, v_name);
    IF v_id IS NULL THEN RETURN jsonb_build_object('text', 'Qual meta apagar? Diga "minhas metas" para ver a lista.', 'kb', 'none'); END IF;
    SELECT * INTO g FROM fin_goals WHERE id = v_id;
    RETURN jsonb_build_object('text', 'Apagar a meta ' || g.name || ' (' || f_brl(g.target) || ')?', 'kb', 'fin_delete', 'rid', -v_id);
  END IF;
  RETURN jsonb_build_object('text', 'Não entendi o que fazer com o planejamento.', 'kb', 'none');
END $$;

-- f_fin: novas acoes
CREATE OR REPLACE FUNCTION f_fin(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE act text := coalesce(p->>'action', ''); res jsonb; intro boolean; d integer;
BEGIN
  PERFORM f_fin_seed(p_user);
  IF act = 'add' THEN res := f_fin_add(p_user, p);
  ELSIF act = 'pay' THEN res := f_fin_pay(p_user, p);
  ELSIF act = 'correct' THEN res := f_fin_correct(p_user, p);
  ELSIF act = 'remove' THEN res := f_fin_remove(p_user, p);
  ELSIF act IN ('summary', 'compare', 'top', 'by_day') THEN res := f_fin_report(p_user, p);
  ELSIF act IN ('budget_set', 'budget_status') THEN res := f_fin_budget(p_user, p);
  ELSIF act IN ('category_create', 'category_list') THEN res := f_fin_category(p_user, p);
  ELSIF act = 'closing_set' THEN res := f_fin_closing(p_user, p);
  ELSIF act = 'owed' THEN res := f_fin_owed(p_user, p);
  ELSIF act IN ('limit_set', 'limit_status', 'limit_clear', 'income_set', 'plan_status', 'goal_create', 'goal_deposit', 'goal_withdraw', 'goal_status', 'goal_edit', 'goal_remove') THEN res := f_fin_plan(p_user, p);
  ELSE res := jsonb_build_object('text', coalesce(nullif(p->>'reply', ''), 'Não entendi o que fazer com o dinheiro. Exemplos: "gastei 42 no mercado", "quanto gastei esse mês?", "orçamento de lazer 300".'), 'kb', 'none');
  END IF;
  SELECT fin_intro_done, fin_closing_day INTO intro, d FROM users WHERE id = p_user;
  IF NOT intro AND act IN ('add', 'summary', 'budget_set', 'budget_status') THEN
    UPDATE users SET fin_intro_done = true WHERE id = p_user;
    res := jsonb_set(res, '{text}', to_jsonb((res->>'text') || E'\n\nDica: seu mês financeiro fecha no dia ' || d || ' (diga "fecha dia 10" para mudar). Quer um orçamento? Ex.: "orçamento de mercado 800".'));
  END IF;
  RETURN res;
END $$;

-- botao Sim apagar / Nao com id negativo = meta
CREATE OR REPLACE FUNCTION f_fin_cb(p_user bigint, p_action text, p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE e fin_entries%ROWTYPE; v_note text := ''; g fin_goals%ROWTYPE;
BEGIN
  IF p_id < 0 THEN
    IF p_action = 'fkeep' THEN RETURN jsonb_build_object('text', 'Ok, mantive a meta.', 'kb', 'none'); END IF;
    SELECT * INTO g FROM fin_goals WHERE id = -p_id AND user_id = p_user;
    IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Essa meta já foi apagada.', 'kb', 'none'); END IF;
    DELETE FROM fin_goals WHERE id = g.id;
    RETURN jsonb_build_object('text', 'Apaguei a meta ' || g.name || '.', 'kb', 'none');
  END IF;
  SELECT * INTO e FROM fin_entries WHERE id = p_id AND user_id = p_user;
  IF p_action = 'fkeep' THEN RETURN jsonb_build_object('text', 'Ok, mantive.', 'kb', 'none'); END IF;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Esse lançamento já foi desfeito ou apagado.', 'kb', 'none'); END IF;
  IF p_action = 'fok' THEN
    IF e.status <> 'draft' THEN RETURN jsonb_build_object('text', 'Esse lançamento já estava confirmado.', 'kb', 'none'); END IF;
    IF e.due_on IS NOT NULL THEN
      UPDATE fin_entries SET status = 'pending' WHERE id = e.id;
      PERFORM f_fin_remind(e.id);
      RETURN jsonb_build_object('text', 'Anotei a pagar: ' || e.description || ' ' || f_brl(e.amount) || ', vence ' || to_char(e.due_on, 'DD/MM') || '. Te aviso no dia.', 'kb', 'fin_undo', 'rid', e.id);
    END IF;
    UPDATE fin_entries SET status = 'paid', paid_on = occurred_on WHERE id = e.id;
    IF e.kind = 'expense' THEN v_note := f_fin_budget_note(p_user, e.category_id, e.amount, e.occurred_on); END IF;
    RETURN jsonb_build_object('text', 'Confirmado: ' || e.description || ' ' || f_brl(e.amount) || '.' || v_note, 'kb', 'fin_undo', 'rid', e.id);
  ELSIF p_action = 'fno' THEN
    IF e.status = 'draft' THEN DELETE FROM fin_entries WHERE id = e.id; END IF;
    RETURN jsonb_build_object('text', 'Ok, descartei. Se quiser, me diga o valor certo.', 'kb', 'none');
  ELSIF p_action IN ('fundo', 'fdel') THEN
    IF e.reminder_id IS NOT NULL THEN
      UPDATE reminders SET status = 'done' WHERE id = e.reminder_id;
      UPDATE notifications SET state = 'cancelled' WHERE reminder_id = e.reminder_id AND state = 'pending';
    END IF;
    IF e.recurring_id IS NOT NULL AND p_action = 'fundo' THEN
      UPDATE fin_recurring SET active = false WHERE id = e.recurring_id AND created_at > now() - interval '30 minutes';
    END IF;
    IF e.series_id IS NOT NULL THEN DELETE FROM fin_entries WHERE series_id = e.series_id AND user_id = p_user;
    ELSE DELETE FROM fin_entries WHERE id = e.id; END IF;
    RETURN jsonb_build_object('text', CASE WHEN p_action = 'fundo' THEN 'Desfeito: ' ELSE 'Apaguei: ' END || e.description || ' ' || f_brl(e.amount) || '.', 'kb', 'none');
  END IF;
  RETURN jsonb_build_object('text', 'Não entendi esse botão.', 'kb', 'none');
END $$;

-- preferencias pequenas: apelido, sem emoji, fuso, resumos
CREATE OR REPLACE FUNCTION f_set_prefs(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE
  t text := ''; v text; tm time; n integer;
BEGIN
  IF nullif(p->>'lead', '') IS NOT NULL THEN
    UPDATE users SET default_lead_minutes = (p->>'lead')::int WHERE id = p_user;
    t := t || E'\nAviso padrão: ' || (p->>'lead') || ' min antes dos compromissos.';
  END IF;
  IF nullif(p->>'supply_days', '') IS NOT NULL THEN
    UPDATE users SET supply_alert_days = (p->>'supply_days')::int WHERE id = p_user;
    t := t || E'\nAviso de estoque: ' || (p->>'supply_days') || ' dia(s) antes de acabar.';
  END IF;
  v := nullif(btrim(coalesce(p->>'summary', '')), '');
  IF v IS NOT NULL THEN
    IF lower(v) IN ('off', 'desligar') THEN UPDATE users SET morning_enabled = false WHERE id = p_user; t := t || E'\nDesliguei o resumo da manhã.';
    ELSIF lower(v) = 'on' THEN UPDATE users SET morning_enabled = true WHERE id = p_user; t := t || E'\nLiguei o resumo da manhã.';
    ELSE BEGIN tm := v::time; UPDATE users SET summary_time = tm, morning_enabled = true WHERE id = p_user; t := t || E'\nResumo da manhã às ' || to_char(tm, 'HH24:MI') || '.';
      EXCEPTION WHEN others THEN t := t || E'\nNão entendi o horário "' || v || '" do resumo da manhã.'; END;
    END IF;
  END IF;
  v := nullif(btrim(coalesce(p->>'evening', '')), '');
  IF v IS NOT NULL THEN
    IF lower(v) = 'off' THEN UPDATE users SET evening_enabled = false WHERE id = p_user; t := t || E'\nDesliguei o resumo do fim do dia.';
    ELSIF lower(v) = 'on' THEN UPDATE users SET evening_enabled = true WHERE id = p_user; t := t || E'\nLiguei o resumo do fim do dia.';
    ELSE BEGIN tm := v::time; UPDATE users SET evening_time = tm, evening_enabled = true WHERE id = p_user; t := t || E'\nResumo do fim do dia às ' || to_char(tm, 'HH24:MI') || '.';
      EXCEPTION WHEN others THEN t := t || E'\nNão entendi o horário "' || v || '" do resumo do fim do dia.'; END;
    END IF;
  END IF;
  IF nullif(btrim(coalesce(p->>'nickname', '')), '') IS NOT NULL THEN
    UPDATE users SET nickname = left(btrim(p->>'nickname'), 30) WHERE id = p_user;
    t := t || E'\nDaqui pra frente te chamo de ' || left(btrim(p->>'nickname'), 30) || '.';
  END IF;
  IF nullif(p->>'no_emoji', '') IS NOT NULL THEN
    UPDATE users SET no_emoji = (p->>'no_emoji')::boolean WHERE id = p_user;
    t := t || CASE WHEN (p->>'no_emoji')::boolean THEN E'\nPronto, sem emoji.' ELSE E'\nCerto, posso usar emoji de novo.' END;
  END IF;
  v := nullif(btrim(coalesce(p->>'timezone', '')), '');
  IF v IS NOT NULL THEN
    SELECT count(*) INTO n FROM pg_timezone_names WHERE name = v;
    IF n = 1 THEN UPDATE users SET timezone = v WHERE id = p_user; t := t || E'\nFuso ajustado para ' || v || '. Lembretes já marcados continuam no horário absoluto.';
    ELSE t := t || E'\nNão reconheci o fuso "' || v || '". Diga a cidade, ex.: Lisboa.'; END IF;
  END IF;
  IF t = '' THEN t := E'\nNão achei nada para mudar.'; END IF;
  RETURN jsonb_build_object('text', 'Pronto:' || t);
END $$;

-- resumos: respeita liga/desliga da manha e usa o apelido
CREATE OR REPLACE FUNCTION f_summary_candidates() RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE v_m jsonb; v_e jsonb;
BEGIN
  WITH due AS (
    UPDATE users u SET last_summary_on = (now() AT TIME ZONE u.timezone)::date
    WHERE u.onboarding_step = 'done' AND u.morning_enabled
      AND u.last_summary_on IS DISTINCT FROM (now() AT TIME ZONE u.timezone)::date
      AND (now() AT TIME ZONE u.timezone)::time >= u.summary_time
      AND (now() AT TIME ZONE u.timezone)::time <  u.summary_time + interval '30 minutes'
    RETURNING u.id, u.telegram_id, coalesce(u.nickname, u.name) AS name, u.timezone, u.calendar_key, u.no_emoji)
  SELECT jsonb_agg(jsonb_build_object('user_id', id, 'chat_id', telegram_id, 'name', name, 'timezone', timezone, 'calendar_key', calendar_key, 'kind', 'morning', 'no_emoji', no_emoji))
  INTO v_m FROM due;
  WITH due AS (
    UPDATE users u SET last_evening_on = (now() AT TIME ZONE u.timezone)::date
    WHERE u.onboarding_step = 'done' AND u.evening_enabled
      AND u.last_evening_on IS DISTINCT FROM (now() AT TIME ZONE u.timezone)::date
      AND (now() AT TIME ZONE u.timezone)::time >= u.evening_time
      AND (now() AT TIME ZONE u.timezone)::time <  u.evening_time + interval '30 minutes'
    RETURNING u.id, u.telegram_id, coalesce(u.nickname, u.name) AS name, u.timezone, u.calendar_key, u.no_emoji)
  SELECT jsonb_agg(jsonb_build_object('user_id', id, 'chat_id', telegram_id, 'name', name, 'timezone', timezone, 'calendar_key', calendar_key, 'kind', 'evening', 'no_emoji', no_emoji))
  INTO v_e FROM due;
  RETURN coalesce(v_m, '[]'::jsonb) || coalesce(v_e, '[]'::jsonb);
END $$;

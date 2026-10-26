-- Fase 2 (extras): lembrete recorrente generico, cartoes e faturas, consultas financeiras novas, pequenos extras.
-- Idempotente (CREATE OR REPLACE / IF NOT EXISTS). Dono de: f_claim_due, f_fin, f_summary_data, f_extras_cb.
-- Nao altera f_create_reminder nem f_fin_add. As colunas series_id/person de reminders pertencem ao modulo da agenda.
SET search_path TO agente, public;

-- ============================================================ 1. LEMBRETE RECORRENTE
ALTER TABLE reminders ADD COLUMN IF NOT EXISTS repeat_rule  text;     -- daily | weekly | monthly
ALTER TABLE reminders ADD COLUMN IF NOT EXISTS repeat_until date;
ALTER TABLE reminders ADD COLUMN IF NOT EXISTS repeat_left  integer;  -- quantas ocorrencias AINDA faltam depois desta (NULL = sem limite)
ALTER TABLE reminders ADD COLUMN IF NOT EXISTS repeat_of    bigint;   -- id da primeira ocorrencia da cadeia (NULL na primeira)
ALTER TABLE reminders ADD COLUMN IF NOT EXISTS card_id      bigint;   -- lembrete de vencimento de fatura (ver fin_cards)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reminders_repeat_rule_chk') THEN
    ALTER TABLE reminders ADD CONSTRAINT reminders_repeat_rule_chk CHECK (repeat_rule IS NULL OR repeat_rule IN ('daily','weekly','monthly'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS reminders_repeat_chain ON reminders ((coalesce(repeat_of, id))) WHERE repeat_rule IS NOT NULL;

-- ============================================================ 2. CARTOES
CREATE TABLE IF NOT EXISTS fin_cards (
  id          bigserial PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        text NOT NULL,
  norm_name   text NOT NULL,
  closing_day integer NOT NULL CHECK (closing_day BETWEEN 1 AND 31),
  due_day     integer NOT NULL CHECK (due_day BETWEEN 1 AND 31),
  card_limit  numeric CHECK (card_limit IS NULL OR card_limit >= 0),
  alert_days  integer NOT NULL DEFAULT 3 CHECK (alert_days BETWEEN 0 AND 20),
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, norm_name)
);
ALTER TABLE fin_entries ADD COLUMN IF NOT EXISTS card_id bigint REFERENCES fin_cards(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS fin_entries_card ON fin_entries (card_id, occurred_on) WHERE card_id IS NOT NULL;

-- ---------- datas do ciclo do cartao
CREATE OR REPLACE FUNCTION f_card_date(p_y integer, p_m integer, p_d integer) RETURNS date
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT (make_date(p_y, p_m, 1) + (least(p_d, extract(day FROM (make_date(p_y, p_m, 1) + interval '1 month - 1 day'))::int) - 1))::date
$$;

-- ultimo fechamento <= p_d
CREATE OR REPLACE FUNCTION f_card_close_le(p_closing integer, p_d date) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path TO 'agente','public' AS $$
DECLARE c date; q date;
BEGIN
  c := f_card_date(extract(year FROM p_d)::int, extract(month FROM p_d)::int, p_closing);
  IF c > p_d THEN
    q := (date_trunc('month', p_d) - interval '1 month')::date;
    c := f_card_date(extract(year FROM q)::int, extract(month FROM q)::int, p_closing);
  END IF;
  RETURN c;
END $$;

-- primeiro fechamento > p_d
CREATE OR REPLACE FUNCTION f_card_close_gt(p_closing integer, p_d date) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path TO 'agente','public' AS $$
DECLARE c date; q date;
BEGIN
  c := f_card_close_le(p_closing, p_d);
  q := (date_trunc('month', c) + interval '1 month')::date;
  RETURN f_card_date(extract(year FROM q)::int, extract(month FROM q)::int, p_closing);
END $$;

-- primeiro vencimento > p_d
CREATE OR REPLACE FUNCTION f_card_due_gt(p_due integer, p_d date) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path TO 'agente','public' AS $$
DECLARE d date; q date;
BEGIN
  d := f_card_date(extract(year FROM p_d)::int, extract(month FROM p_d)::int, p_due);
  IF d <= p_d THEN
    q := (date_trunc('month', p_d) + interval '1 month')::date;
    d := f_card_date(extract(year FROM q)::int, extract(month FROM q)::int, p_due);
  END IF;
  RETURN d;
END $$;

-- soma da fatura: lancamentos do cartao com data em [p_from, p_to). Compra no dia do fechamento cai na fatura seguinte.
CREATE OR REPLACE FUNCTION f_card_sum(p_card bigint, p_from date, p_to date) RETURNS numeric
LANGUAGE sql STABLE SET search_path TO 'agente','public' AS $$
  SELECT coalesce(sum(amount), 0) FROM fin_entries
  WHERE card_id = p_card AND kind = 'expense' AND status IN ('paid','pending') AND occurred_on >= p_from AND occurred_on < p_to
$$;

CREATE OR REPLACE FUNCTION f_days_text(p_n integer) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT CASE WHEN p_n = 0 THEN 'hoje' WHEN p_n = 1 THEN 'amanhã' WHEN p_n > 1 THEN 'em ' || p_n || ' dias'
              WHEN p_n = -1 THEN 'ontem' ELSE 'há ' || (-p_n) || ' dias' END
$$;

-- achar cartao do usuario por nome aproximado (NULL se nao achar)
CREATE OR REPLACE FUNCTION f_card_find(p_user bigint, p_hint text) RETURNS bigint
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE h text; v bigint;
BEGIN
  h := f_norm(regexp_replace(btrim(coalesce(p_hint, '')), '^((o|a) )?(cart[aã]o|cr[eé]dito)?( ?(do|da|de|no|na))? ', '', 'i'));
  IF h = '' THEN h := f_norm(p_hint); END IF;
  IF h = '' THEN RETURN NULL; END IF;
  SELECT id INTO v FROM fin_cards WHERE user_id = p_user AND active AND norm_name = h;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT id INTO v FROM fin_cards WHERE user_id = p_user AND active AND (norm_name LIKE '%' || h || '%' OR h LIKE '%' || norm_name || '%') ORDER BY id LIMIT 1;
  RETURN v;
END $$;

-- proximo aviso de vencimento de fatura depois de p_after (e depois de agora): vencimento - alert_days as 09:00 local
CREATE OR REPLACE FUNCTION f_card_next_alert(p_card bigint, p_after timestamptz DEFAULT now()) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE c fin_cards%ROWTYPE; tz text; dd date; ts timestamptz; n integer := 0; lim timestamptz := greatest(coalesce(p_after, now()), now());
BEGIN
  SELECT * INTO c FROM fin_cards WHERE id = p_card;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT timezone INTO tz FROM users WHERE id = c.user_id;
  dd := f_card_due_gt(c.due_day, (now() AT TIME ZONE tz)::date - 1);
  LOOP
    ts := ((dd - c.alert_days) + time '09:00') AT TIME ZONE tz;
    EXIT WHEN ts > lim OR n > 6;
    dd := f_card_due_gt(c.due_day, dd); n := n + 1;
  END LOOP;
  RETURN ts;
END $$;

-- texto do aviso, calculado na hora em que o lembrete dispara (valor da fatura que vence)
CREATE OR REPLACE FUNCTION f_card_alert_title(p_card bigint, p_due_at timestamptz) RETURNS text
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE c fin_cards%ROWTYPE; tz text; a date; dd date; cl date; pr date; amt numeric;
BEGIN
  SELECT * INTO c FROM fin_cards WHERE id = p_card;
  IF NOT FOUND THEN RETURN 'Fatura do cartão vence em breve'; END IF;
  SELECT timezone INTO tz FROM users WHERE id = c.user_id;
  a := (p_due_at AT TIME ZONE tz)::date;
  dd := f_card_due_gt(c.due_day, a + c.alert_days - 1);          -- vencimento a que este aviso se refere
  cl := f_card_close_le(c.closing_day, dd - 1);                   -- fechamento dessa fatura
  pr := f_card_close_le(c.closing_day, cl - 1);
  amt := f_card_sum(c.id, pr, cl);
  RETURN 'Fatura do cartão ' || c.name || ' vence dia ' || to_char(dd, 'DD/MM') || ' (' || f_days_text(dd - a) || ')' ||
    CASE WHEN amt > 0 THEN ': ' || f_brl(amt) || CASE WHEN cl > a THEN ' até agora (fecha dia ' || to_char(cl, 'DD/MM') || ')' ELSE '' END ELSE '' END;
END $$;

-- recria o lembrete mensal de vencimento da fatura (cancela os pendentes do cartao e cria o proximo)
CREATE OR REPLACE FUNCTION f_card_alert_sync(p_card bigint) RETURNS void
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE c fin_cards%ROWTYPE; ts timestamptz; v_rid bigint;
BEGIN
  UPDATE notifications SET state = 'cancelled'
   WHERE state = 'pending' AND reminder_id IN (SELECT id FROM reminders WHERE card_id = p_card AND status = 'pending');
  UPDATE reminders SET status = 'cancelled', repeat_rule = NULL WHERE card_id = p_card AND status = 'pending';
  SELECT * INTO c FROM fin_cards WHERE id = p_card AND active;
  IF NOT FOUND THEN RETURN; END IF;
  ts := f_card_next_alert(p_card, now());
  INSERT INTO reminders (user_id, kind, title, due_at, status, source, repeat_rule, card_id)
  VALUES (c.user_id, 'reminder', 'Fatura do cartão ' || c.name || ' vence dia ' || c.due_day, ts, 'pending', 'text', 'monthly', p_card)
  RETURNING id INTO v_rid;
  INSERT INTO notifications (user_id, reminder_id, type, fire_at) VALUES (c.user_id, v_rid, 'reminder', ts);
END $$;

-- estado/texto de um cartao
CREATE OR REPLACE FUNCTION f_card_status_text(p_card bigint) RETURNS text
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE c fin_cards%ROWTYPE; today date; s date; e date; pv date; open_amt numeric; closed_amt numeric; due_closed date; due_open date;
        fut numeric; avail numeric; unpaid boolean; t text;
BEGIN
  SELECT * INTO c FROM fin_cards WHERE id = p_card;
  IF NOT FOUND THEN RETURN 'Não achei esse cartão.'; END IF;
  today := f_fin_today(c.user_id);
  s := f_card_close_le(c.closing_day, today);        -- fechamento mais recente (inicio da fatura aberta)
  e := f_card_close_gt(c.closing_day, today);        -- proximo fechamento
  pv := f_card_close_le(c.closing_day, s - 1);       -- fechamento anterior
  open_amt := f_card_sum(c.id, s, e);
  closed_amt := f_card_sum(c.id, pv, s);
  due_closed := f_card_due_gt(c.due_day, s);
  due_open := f_card_due_gt(c.due_day, e);
  unpaid := closed_amt > 0 AND today <= due_closed;
  fut := f_card_sum(c.id, e, date '9999-01-01');
  t := 'Cartão ' || c.name || ' (fecha dia ' || c.closing_day || ', vence dia ' || c.due_day || '):' ||
       E'\n- Fatura aberta: ' || f_brl(open_amt) || ' (fecha ' || to_char(e, 'DD/MM') || ', ' || f_days_text(e - today) || '; vence ' || to_char(due_open, 'DD/MM') || ')' ||
       E'\n- Última fatura (fechou ' || to_char(s, 'DD/MM') || '): ' ||
         CASE WHEN closed_amt = 0 THEN 'sem lançamentos'
              WHEN unpaid THEN f_brl(closed_amt) || ', vence ' || to_char(due_closed, 'DD/MM') || ' (' || f_days_text(due_closed - today) || ')'
              ELSE f_brl(closed_amt) || ', venceu ' || to_char(due_closed, 'DD/MM') || ' (considero paga)' END;
  IF c.card_limit IS NOT NULL THEN
    avail := c.card_limit - open_amt - CASE WHEN unpaid THEN closed_amt ELSE 0 END;
    t := t || E'\n- Limite ' || f_brl(c.card_limit) || ': disponível ' || CASE WHEN avail < 0 THEN '-' ELSE '' END || f_brl(abs(avail)) ||
         ' (limite menos fatura aberta' || CASE WHEN unpaid THEN ' e fatura fechada a pagar' ELSE '' END || ')';
  ELSE
    t := t || E'\n- Sem limite cadastrado (diga "limite do cartão ' || c.name || ' é 5000").';
  END IF;
  IF fut > 0 THEN t := t || E'\n- Parcelas e lançamentos de meses seguintes: ' || f_brl(fut); END IF;
  RETURN t;
END $$;

-- usado no resumo da manha: cartao com fatura fechada vencendo em ate 3 dias
CREATE OR REPLACE FUNCTION f_card_due_info(p_card bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE c fin_cards%ROWTYPE; today date; s date; pv date; amt numeric; dd date;
BEGIN
  SELECT * INTO c FROM fin_cards WHERE id = p_card AND active;
  IF NOT FOUND THEN RETURN NULL; END IF;
  today := f_fin_today(c.user_id);
  s := f_card_close_le(c.closing_day, today);
  pv := f_card_close_le(c.closing_day, s - 1);
  dd := f_card_due_gt(c.due_day, s);
  amt := f_card_sum(c.id, pv, s);
  IF amt > 0 AND dd - today BETWEEN 0 AND 3 THEN
    RETURN jsonb_build_object('name', c.name, 'amount', amt, 'due', to_char(dd, 'DD/MM'), 'days', dd - today);
  END IF;
  RETURN NULL;
END $$;

-- ============================================================ 3. LEMBRETE RECORRENTE: funcoes
-- cria lembrete (embrulha f_create_reminder). p_repeat = {"freq":"daily|weekly|monthly","until":"YYYY-MM-DD","count":N}
CREATE OR REPLACE FUNCTION f_reminder_create_ex(p_user bigint, p_title text, p_due timestamptz, p_shared boolean DEFAULT false,
    p_lead integer DEFAULT NULL, p_source text DEFAULT 'text', p_repeat jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE res jsonb; v_freq text := lower(nullif(p_repeat->>'freq', '')); v_until date := f_safe_date(p_repeat->>'until');
        v_cnt integer; v_rid bigint; v_grp uuid; tz text; loc timestamp; lbl text;
        dow text[] := ARRAY['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
BEGIN
  BEGIN v_cnt := nullif(p_repeat->>'count', '')::int; EXCEPTION WHEN others THEN v_cnt := NULL; END;
  res := f_create_reminder(p_user, p_title, p_due, p_shared, p_lead, 'reminder', NULL, coalesce(p_source, 'text'));
  IF v_freq IS NULL OR v_freq NOT IN ('daily','weekly','monthly') THEN RETURN res; END IF;
  v_rid := (res->>'reminder_id')::bigint;
  SELECT shared_group INTO v_grp FROM reminders WHERE id = v_rid;
  UPDATE reminders SET repeat_rule = v_freq, repeat_until = v_until,
         repeat_left = CASE WHEN v_cnt IS NOT NULL AND v_cnt >= 1 THEN v_cnt - 1 END
   WHERE id = v_rid OR (v_grp IS NOT NULL AND shared_group = v_grp);
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  loc := p_due AT TIME ZONE tz;
  lbl := CASE v_freq
    WHEN 'daily' THEN 'todo dia'
    WHEN 'weekly' THEN CASE WHEN extract(dow FROM loc) IN (0, 6) THEN 'todo ' ELSE 'toda ' END || dow[extract(dow FROM loc)::int + 1]
    ELSE 'todo dia ' || extract(day FROM loc)::int END || ' às ' || to_char(loc, 'HH24:MI') ||
    CASE WHEN v_until IS NOT NULL THEN ' (até ' || to_char(v_until, 'DD/MM/YYYY') || ')'
         WHEN v_cnt IS NOT NULL AND v_cnt > 1 THEN ' (' || v_cnt || ' vezes)' ELSE '' END;
  RETURN res || jsonb_build_object('repeat_rule', v_freq, 'repeat_text', lbl);
END $$;

-- agenda a proxima ocorrencia de um lembrete recorrente (chamada quando a notificacao dele e reivindicada)
CREATE OR REPLACE FUNCTION f_reminder_advance(p_rid bigint) RETURNS bigint
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE r reminders%ROWTYPE; root reminders%ROWTYPE; c fin_cards%ROWTYPE; tz text; v_chain bigint; v_loc timestamp; v_nxt timestamptz;
        v_left integer; v_lead integer; v_new bigint; v_anchor integer; m date; n integer := 0; v_title text;
BEGIN
  SELECT * INTO r FROM reminders WHERE id = p_rid;
  IF NOT FOUND OR r.repeat_rule IS NULL OR r.status <> 'pending' THEN RETURN NULL; END IF;
  v_chain := coalesce(r.repeat_of, r.id);
  -- a ocorrencia anterior (ainda aberta) fecha quando a nova dispara: nao acumula repeticoes
  UPDATE notifications SET state = 'cancelled'
   WHERE state = 'pending' AND reminder_id IN (SELECT id FROM reminders WHERE coalesce(repeat_of, id) = v_chain AND id < r.id AND user_id = r.user_id);
  UPDATE reminders SET status = 'done' WHERE coalesce(repeat_of, id) = v_chain AND id < r.id AND user_id = r.user_id AND status = 'pending';
  -- ja existe uma proxima (ex.: o lembrete foi adiado e disparou de novo)
  IF EXISTS (SELECT 1 FROM reminders WHERE coalesce(repeat_of, id) = v_chain AND id > r.id AND user_id = r.user_id AND status = 'pending') THEN RETURN NULL; END IF;
  SELECT timezone INTO tz FROM users WHERE id = r.user_id;
  IF r.card_id IS NOT NULL THEN
    SELECT * INTO c FROM fin_cards WHERE id = r.card_id AND active;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_nxt := f_card_next_alert(c.id, r.due_at);
    v_title := 'Fatura do cartão ' || c.name || ' vence dia ' || c.due_day;
    v_left := NULL;
  ELSE
    SELECT * INTO root FROM reminders WHERE id = v_chain;
    v_anchor := extract(day FROM (coalesce(root.due_at, r.due_at) AT TIME ZONE tz))::int;
    v_loc := r.due_at AT TIME ZONE tz;
    v_left := r.repeat_left;
    LOOP
      n := n + 1;
      IF n > 800 THEN RETURN NULL; END IF;
      IF v_left IS NOT NULL AND v_left <= 0 THEN RETURN NULL; END IF;
      IF r.repeat_rule = 'daily' THEN v_loc := v_loc + interval '1 day';
      ELSIF r.repeat_rule = 'weekly' THEN v_loc := v_loc + interval '7 days';
      ELSE
        m := (date_trunc('month', v_loc) + interval '1 month')::date;
        v_loc := (m + (least(v_anchor, extract(day FROM (m + interval '1 month - 1 day'))::int) - 1)) + v_loc::time;
      END IF;
      v_nxt := v_loc AT TIME ZONE tz;
      IF v_left IS NOT NULL THEN v_left := v_left - 1; END IF;
      EXIT WHEN v_nxt > now();      -- se o robo ficou fora do ar, pula as ocorrencias que ja passaram
    END LOOP;
    IF r.repeat_until IS NOT NULL AND v_loc::date > r.repeat_until THEN RETURN NULL; END IF;
    v_title := r.title;
  END IF;
  INSERT INTO reminders (user_id, kind, title, due_at, status, shared_group, source, repeat_rule, repeat_until, repeat_left, repeat_of, card_id)
  VALUES (r.user_id, 'reminder', v_title, v_nxt, 'pending', r.shared_group, r.source, r.repeat_rule, r.repeat_until, v_left, v_chain, r.card_id)
  RETURNING id INTO v_new;
  INSERT INTO notifications (user_id, reminder_id, type, fire_at) VALUES (r.user_id, v_new, 'reminder', v_nxt);
  SELECT offset_minutes INTO v_lead FROM notifications WHERE reminder_id = r.id AND type = 'pre_alert' ORDER BY id LIMIT 1;
  IF v_lead IS NOT NULL AND v_lead > 0 AND v_nxt - make_interval(mins => v_lead) > now() THEN
    INSERT INTO notifications (user_id, reminder_id, type, fire_at, offset_minutes)
    VALUES (r.user_id, v_new, 'pre_alert', v_nxt - make_interval(mins => v_lead), v_lead);
  END IF;
  RETURN v_new;
END $$;

-- cancela lembrete(s) pendente(s) por titulo e encerra a repeticao (mais de um candidato: lista e pede um nome mais especifico)
CREATE OR REPLACE FUNCTION f_reminder_cancel(p_user bigint, p_title text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE q text := f_norm(p_title); toks text[]; n integer := 0; v_chain bigint; v_ttl text; v_rec boolean; r record; t text := ''; tz text;
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  IF q = '' THEN
    RETURN jsonb_build_object('text', 'Qual lembrete eu cancelo? Diga o nome, por exemplo: "cancela o lembrete da conta de luz".', 'kb', 'none');
  END IF;
  SELECT array_agg(x) INTO toks FROM unnest(string_to_array(q, ' ')) x
   WHERE length(x) >= 3 AND x NOT IN ('que','com','pra','para','dos','das','meu','minha','lembrete','lembrar','lembra','cancela','cancelar','apaga','apagar','toda','todo','todos');
  IF toks IS NULL THEN toks := ARRAY[q]; END IF;
  FOR r IN
    SELECT DISTINCT ON (coalesce(rm.repeat_of, rm.id)) coalesce(rm.repeat_of, rm.id) AS chain, rm.title, rm.due_at, rm.repeat_rule IS NOT NULL AS rec
    FROM reminders rm
    WHERE rm.user_id = p_user AND rm.status IN ('pending','awaiting_time') AND rm.kind = 'reminder' AND rm.card_id IS NULL
      AND (SELECT bool_and(f_norm(rm.title) LIKE '%' || x || '%') FROM unnest(toks) x)
    ORDER BY coalesce(rm.repeat_of, rm.id), rm.due_at
  LOOP
    n := n + 1;
    IF n = 1 THEN v_chain := r.chain; v_ttl := r.title; v_rec := r.rec; END IF;
    IF n <= 6 THEN
      t := t || E'\n- ' || r.title || ' (' || to_char(r.due_at AT TIME ZONE tz, 'DD/MM HH24:MI') || CASE WHEN r.rec THEN ', se repete' ELSE '' END || ')';
    END IF;
  END LOOP;
  IF n = 0 THEN
    RETURN jsonb_build_object('text', 'Não achei nenhum lembrete pendente parecido com "' || btrim(p_title) || '".', 'kb', 'none');
  END IF;
  IF n > 1 THEN
    RETURN jsonb_build_object('text', 'Achei ' || n || ' lembretes parecidos:' || t || E'\nMe diga o nome com mais detalhe para eu saber qual cancelar.', 'kb', 'none');
  END IF;
  UPDATE notifications SET state = 'cancelled'
   WHERE state = 'pending' AND reminder_id IN (SELECT id FROM reminders WHERE user_id = p_user AND coalesce(repeat_of, id) = v_chain AND status IN ('pending','awaiting_time'));
  UPDATE reminders SET status = 'cancelled' WHERE user_id = p_user AND coalesce(repeat_of, id) = v_chain AND status IN ('pending','awaiting_time');
  UPDATE reminders SET repeat_rule = NULL WHERE user_id = p_user AND coalesce(repeat_of, id) = v_chain AND repeat_rule IS NOT NULL;
  RETURN jsonb_build_object('text', 'Cancelei o lembrete "' || v_ttl || '"' || CASE WHEN v_rec THEN ' e a repetição dele' ELSE '' END || '.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_reminder_cancel: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui cancelar agora. Tente de novo.', 'kb', 'none');
END $$;

-- ============================================================ 4. f_claim_due (agenda a proxima ocorrencia dos recorrentes)
CREATE OR REPLACE FUNCTION f_claim_due() RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE v jsonb; v_claimed jsonb; x record;
BEGIN
  PERFORM f_enqueue_doses();
  PERFORM f_fin_materialize();
  WITH claimed AS (
    UPDATE notifications n SET state = 'sent', sent_at = now()
    WHERE n.id IN (
      SELECT y.id FROM notifications y
      WHERE y.state = 'pending' AND y.fire_at <= now()
        AND (y.reminder_id IS NULL OR EXISTS (SELECT 1 FROM reminders r WHERE r.id = y.reminder_id AND r.status = 'pending'))
        AND (y.dose_id IS NULL OR EXISTS (SELECT 1 FROM supply_doses dd WHERE dd.id = y.dose_id AND dd.status = 'pending'))
      ORDER BY y.fire_at LIMIT 20 FOR UPDATE SKIP LOCKED)
    RETURNING n.*)
  SELECT coalesce(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb) INTO v_claimed FROM claimed;

  -- lembrete que se repete: agenda a proxima ocorrencia (e fecha a anterior)
  FOR x IN SELECT c.reminder_id FROM jsonb_populate_recordset(NULL::notifications, v_claimed) c WHERE c.type = 'reminder' AND c.reminder_id IS NOT NULL LOOP
    BEGIN
      PERFORM f_reminder_advance(x.reminder_id);
    EXCEPTION WHEN others THEN
      RAISE WARNING 'f_reminder_advance(%): %', x.reminder_id, SQLERRM;
    END;
  END LOOP;

  INSERT INTO notifications(user_id, reminder_id, type, fire_at)
  SELECT c.user_id, c.reminder_id, 'repeat', now() + interval '15 minutes'
  FROM jsonb_populate_recordset(NULL::notifications, v_claimed) c WHERE c.type = 'reminder';
  INSERT INTO notifications(user_id, supply_id, dose_id, type, fire_at)
  SELECT c.user_id, c.supply_id, c.dose_id, 'dose', now() + interval '10 minutes'
  FROM jsonb_populate_recordset(NULL::notifications, v_claimed) c JOIN users u ON u.id = c.user_id
  WHERE c.type = 'dose' AND (now() AT TIME ZONE u.timezone)::time < time '23:30';

  SELECT jsonb_agg(jsonb_build_object(
      'notification_id', c.id, 'type', c.type, 'chat_id', u.telegram_id, 'user_name', u.name,
      'reminder_id', c.reminder_id,
      'title', CASE WHEN r.card_id IS NOT NULL THEN f_card_alert_title(r.card_id, r.due_at) ELSE r.title END,
      'due', to_char(r.due_at AT TIME ZONE u.timezone, 'DD/MM HH24:MI'),
      'offset_minutes', c.offset_minutes, 'supply_id', c.supply_id, 'dose_id', c.dose_id, 'item', s.item,
      'days_left', (s.runs_out_on - CURRENT_DATE)))
  INTO v
  FROM jsonb_populate_recordset(NULL::notifications, v_claimed) c JOIN users u ON u.id = c.user_id
  LEFT JOIN reminders r ON r.id = c.reminder_id
  LEFT JOIN supplies_status s ON s.id = c.supply_id;
  RETURN v;
END $$;

-- ============================================================ 5. CONSULTAS FINANCEIRAS NOVAS
CREATE OR REPLACE FUNCTION f_fin_month(p_user bigint, p_month text, p_period text, OUT m_start date, OUT m_end date, OUT m_label text)
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE cs date; off integer; yy integer; mm integer;
  nm text[] := ARRAY['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro'];
BEGIN
  IF p_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$' THEN
    yy := substr(p_month, 1, 4)::int; mm := substr(p_month, 6, 2)::int;
    SELECT p_start INTO cs FROM f_fin_period(p_user, 0);
    off := (yy - extract(year FROM cs)::int) * 12 + mm - extract(month FROM cs)::int;
    SELECT p_start, p_end INTO m_start, m_end FROM f_fin_period(p_user, off);
    m_label := 'em ' || nm[mm] || CASE WHEN yy <> extract(year FROM f_fin_today(p_user))::int THEN ' de ' || yy ELSE '' END;
  ELSE
    SELECT r_start, r_end, r_label INTO m_start, m_end, m_label FROM f_fin_range(p_user, coalesce(nullif(p_period, ''), 'current'));
    m_label := CASE m_label WHEN 'mês atual' THEN 'no mês atual' WHEN 'mês anterior' THEN 'no mês anterior' WHEN 'últimos 7 dias' THEN 'nos últimos 7 dias' ELSE m_label END;
  END IF;
  m_label := m_label || ' (' || to_char(m_start, 'DD/MM') || ' a ' || to_char(m_end, 'DD/MM') || ')';
END $$;

CREATE OR REPLACE FUNCTION f_fin_query(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE act text := coalesce(p->>'action', ''); ms date; me date; lbl text; today date := f_fin_today(p_user);
        hint text; cat bigint; catname text; bud numeric; v_sum numeric; v_n integer; t text := ''; r record; v_meth text; v_com numeric := 0; v_inst numeric := 0; k integer := 0;
BEGIN
  SELECT m_start, m_end, m_label INTO ms, me, lbl FROM f_fin_month(p_user, coalesce(p->>'month', ''), coalesce(p->>'period', ''));

  IF act = 'category_total' THEN
    hint := coalesce(nullif(btrim(p->>'category'), ''), nullif(btrim(p->>'title'), ''), '');
    IF hint = '' THEN
      RETURN jsonb_build_object('text', 'De qual categoria? Ex.: "quanto foi de mercado em agosto?".', 'kb', 'none');
    END IF;
    cat := f_fin_cat_find(p_user, 'expense', hint, f_norm(hint));
    IF cat IS NOT NULL THEN
      SELECT name, budget INTO catname, bud FROM fin_categories WHERE id = cat;
      SELECT coalesce(sum(amount), 0), count(*) INTO v_sum, v_n FROM fin_entries
       WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND category_id = cat AND occurred_on BETWEEN ms AND me;
      t := catname || ' ' || lbl || ': ' || f_brl(v_sum) || CASE WHEN v_n > 0 THEN ' (' || v_n || ' lançamento' || CASE WHEN v_n > 1 THEN 's' ELSE '' END || ')' ELSE ' (nenhum lançamento)' END || '.';
      IF bud IS NOT NULL THEN t := t || ' Orçamento ' || f_brl(bud) || ': ' || round(v_sum / bud * 100) || '%.'; END IF;
      FOR r IN SELECT description, amount, occurred_on FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND category_id = cat AND occurred_on BETWEEN ms AND me ORDER BY amount DESC LIMIT 3 LOOP
        IF k = 0 THEN t := t || E'\nMaiores:'; END IF; k := k + 1;
        t := t || E'\n- ' || r.description || ' ' || f_brl(r.amount) || ' (' || to_char(r.occurred_on, 'DD/MM') || ')';
      END LOOP;
      RETURN jsonb_build_object('text', t, 'kb', 'none');
    END IF;
    -- sem categoria com esse nome: procura na descricao dos lancamentos
    SELECT coalesce(sum(amount), 0), count(*) INTO v_sum, v_n FROM fin_entries
     WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND norm_desc LIKE '%' || f_norm(hint) || '%' AND occurred_on BETWEEN ms AND me;
    IF v_n > 0 THEN
      RETURN jsonb_build_object('text', 'Não tenho categoria "' || hint || '", mas lançamentos com esse nome ' || lbl || ' somam ' || f_brl(v_sum) || ' (' || v_n || ').', 'kb', 'none');
    END IF;
    SELECT string_agg(name, ', ' ORDER BY name) INTO t FROM fin_categories WHERE user_id = p_user AND kind = 'expense';
    RETURN jsonb_build_object('text', 'Não achei a categoria "' || hint || '". Suas categorias: ' || coalesce(t, '-') || '.', 'kb', 'none');
  END IF;

  IF act = 'method_total' THEN
    v_meth := nullif(p->>'method', '');
    IF v_meth IS NULL THEN
      FOR r IN SELECT coalesce(method, 'sem forma') AS m, sum(amount) s, count(*) n FROM fin_entries
               WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN ms AND me GROUP BY 1 ORDER BY 2 DESC LOOP
        k := k + 1; t := t || E'\n- ' || r.m || ': ' || f_brl(r.s) || ' (' || r.n || ')';
      END LOOP;
      IF k = 0 THEN RETURN jsonb_build_object('text', 'Nenhum gasto registrado ' || lbl || '.', 'kb', 'none'); END IF;
      RETURN jsonb_build_object('text', 'Gastos por forma de pagamento ' || lbl || ':' || t, 'kb', 'none');
    END IF;
    SELECT coalesce(sum(amount), 0), count(*) INTO v_sum, v_n FROM fin_entries
     WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND method = v_meth AND occurred_on BETWEEN ms AND me;
    t := 'Gastos ' || CASE v_meth WHEN 'credito' THEN 'no crédito' WHEN 'debito' THEN 'no débito' WHEN 'pix' THEN 'no Pix' WHEN 'dinheiro' THEN 'em dinheiro' WHEN 'boleto' THEN 'no boleto' ELSE v_meth END ||
         ' ' || lbl || ': ' || f_brl(v_sum) || ' (' || v_n || ' lançamento' || CASE WHEN v_n <> 1 THEN 's' ELSE '' END || ').';
    FOR r IN SELECT description, amount, occurred_on FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND method = v_meth AND occurred_on BETWEEN ms AND me ORDER BY amount DESC LIMIT 3 LOOP
      IF k = 0 THEN t := t || E'\nMaiores:'; END IF; k := k + 1;
      t := t || E'\n- ' || r.description || ' ' || f_brl(r.amount) || ' (' || to_char(r.occurred_on, 'DD/MM') || ')';
    END LOOP;
    RETURN jsonb_build_object('text', t, 'kb', 'none');
  END IF;

  IF act = 'left_to_close' THEN
    SELECT p_end INTO me FROM f_fin_period(p_user, 0);
    RETURN jsonb_build_object('text', f_fin_plan_text(p_user) || E'\n\nO mês financeiro vai até ' || to_char(me, 'DD/MM') || ' (faltam ' || (me - today + 1) || ' dia' || CASE WHEN me - today + 1 <> 1 THEN 's' ELSE '' END || ', contando hoje).', 'kb', 'none');
  END IF;

  IF act = 'committed' THEN
    -- sem mes informado: o proximo periodo (o que ainda vem pela frente)
    IF coalesce(p->>'month', '') !~ '^[0-9]{4}-[0-9]{2}$' THEN
      SELECT p_start, p_end INTO ms, me FROM f_fin_period(p_user, 1);
      lbl := 'no próximo mês (' || to_char(ms, 'DD/MM') || ' a ' || to_char(me, 'DD/MM') || ')';
    END IF;
    SELECT coalesce(sum(amount), 0) INTO v_com FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'pending' AND due_on BETWEEN ms AND me;
    SELECT coalesce(sum(amount), 0) INTO v_inst FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on > today AND occurred_on BETWEEN ms AND me;
    IF v_com + v_inst = 0 THEN
      RETURN jsonb_build_object('text', 'Nada comprometido ' || lbl || ' (sem contas a pagar nem parcelas com data nesse período).', 'kb', 'none');
    END IF;
    t := 'Comprometido ' || lbl || ': ' || f_brl(v_com + v_inst) || E'\n- Contas a pagar: ' || f_brl(v_com) || E'\n- Parcelas e lançamentos futuros: ' || f_brl(v_inst);
    FOR r IN SELECT description, amount, coalesce(due_on, occurred_on) AS d, status, installment_no, installments FROM fin_entries
             WHERE user_id = p_user AND kind = 'expense' AND ((status = 'pending' AND due_on BETWEEN ms AND me) OR (status = 'paid' AND occurred_on > today AND occurred_on BETWEEN ms AND me))
             ORDER BY coalesce(due_on, occurred_on), id LIMIT 8 LOOP
      IF k = 0 THEN t := t || E'\nItens:'; END IF; k := k + 1;
      t := t || E'\n- ' || r.description || ' ' || f_brl(r.amount) || ' (' || to_char(r.d, 'DD/MM') || CASE WHEN r.installments IS NOT NULL THEN ', parcela ' || r.installment_no || '/' || r.installments ELSE '' END || ')';
    END LOOP;
    RETURN jsonb_build_object('text', t, 'kb', 'none');
  END IF;

  RETURN jsonb_build_object('text', 'Não entendi essa consulta.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_fin_query: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui calcular isso agora. Tente de novo em instantes.', 'kb', 'none');
END $$;

-- ============================================================ 6. CARTOES: acoes do f_fin
CREATE OR REPLACE FUNCTION f_card_action(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE act text := coalesce(p->>'action', ''); hint text; nm text; cid bigint; c fin_cards%ROWTYPE; cl integer; du integer; lim numeric; al integer; t text := ''; n integer; r record;
BEGIN
  -- o campo title vem sempre preenchido pelo modelo: so serve de reserva para cadastrar/editar
  hint := coalesce(nullif(btrim(p->>'card'), ''), CASE WHEN act IN ('card_create', 'card_edit') THEN nullif(btrim(p->>'title'), '') END, '');
  nm := btrim(regexp_replace(hint, '^((o|a) )?cart[aã]o( ?(do|da|de))? ', '', 'i'));
  BEGIN cl := nullif(p->>'card_closing_day', '')::int; EXCEPTION WHEN others THEN cl := NULL; END;
  BEGIN du := nullif(p->>'card_due_day', '')::int; EXCEPTION WHEN others THEN du := NULL; END;
  BEGIN lim := nullif(p->>'card_limit', '')::numeric; EXCEPTION WHEN others THEN lim := NULL; END;
  BEGIN al := nullif(p->>'alert_days', '')::int; EXCEPTION WHEN others THEN al := NULL; END;
  IF cl IS NOT NULL AND cl NOT BETWEEN 1 AND 31 THEN cl := NULL; END IF;
  IF du IS NOT NULL AND du NOT BETWEEN 1 AND 31 THEN du := NULL; END IF;
  IF al IS NOT NULL AND al NOT BETWEEN 0 AND 20 THEN al := NULL; END IF;
  IF lim IS NOT NULL AND lim < 0 THEN lim := NULL; END IF;

  IF act IN ('card_create', 'card_edit') THEN
    cid := f_card_find(p_user, nm);
    IF cid IS NULL AND nm = '' THEN
      SELECT count(*) INTO n FROM fin_cards WHERE user_id = p_user AND active;
      IF n = 1 THEN SELECT id INTO cid FROM fin_cards WHERE user_id = p_user AND active; END IF;
    END IF;
    IF cid IS NULL THEN
      IF nm = '' THEN
        RETURN jsonb_build_object('text', 'Qual é o nome do cartão? Ex.: "cartão Itaú fecha dia 10 vence dia 17 limite 5000".', 'kb', 'none');
      END IF;
      IF cl IS NULL OR du IS NULL THEN
        RETURN jsonb_build_object('text', 'Para cadastrar o cartão ' || nm || ', me diga o dia que a fatura fecha e o dia que vence. Ex.: "cartão ' || nm || ' fecha dia 10 vence dia 17 limite 5000".', 'kb', 'none');
      END IF;
      INSERT INTO fin_cards (user_id, name, norm_name, closing_day, due_day, card_limit, alert_days)
      VALUES (p_user, left(nm, 40), f_norm(nm), cl, du, lim, coalesce(al, 3))
      ON CONFLICT (user_id, norm_name) DO UPDATE SET closing_day = EXCLUDED.closing_day, due_day = EXCLUDED.due_day,
        card_limit = coalesce(EXCLUDED.card_limit, fin_cards.card_limit), alert_days = EXCLUDED.alert_days, active = true
      RETURNING id INTO cid;
      PERFORM f_card_alert_sync(cid);
      SELECT * INTO c FROM fin_cards WHERE id = cid;
      RETURN jsonb_build_object('text', 'Cadastrei o cartão ' || c.name || ': fecha dia ' || c.closing_day || ', vence dia ' || c.due_day ||
        CASE WHEN c.card_limit IS NOT NULL THEN ', limite ' || f_brl(c.card_limit) ELSE '' END || '. Te aviso ' || c.alert_days || ' dia' || CASE WHEN c.alert_days <> 1 THEN 's' ELSE '' END ||
        ' antes do vencimento, às 9h. Para lançar: "almoço 40 no cartão ' || c.name || '".', 'kb', 'none');
    END IF;
    -- editar
    IF cl IS NULL AND du IS NULL AND lim IS NULL AND al IS NULL THEN
      SELECT * INTO c FROM fin_cards WHERE id = cid;
      RETURN jsonb_build_object('text', 'O cartão ' || c.name || ' hoje fecha dia ' || c.closing_day || ', vence dia ' || c.due_day ||
        CASE WHEN c.card_limit IS NOT NULL THEN ', limite ' || f_brl(c.card_limit) ELSE ', sem limite' END || '. O que mudo? Ex.: "fecha dia 12", "limite 6000", "me avisa 5 dias antes".', 'kb', 'none');
    END IF;
    UPDATE fin_cards SET closing_day = coalesce(cl, closing_day), due_day = coalesce(du, due_day), card_limit = coalesce(lim, card_limit), alert_days = coalesce(al, alert_days)
     WHERE id = cid RETURNING * INTO c;
    PERFORM f_card_alert_sync(cid);
    RETURN jsonb_build_object('text', 'Atualizei o cartão ' || c.name || ': fecha dia ' || c.closing_day || ', vence dia ' || c.due_day ||
      CASE WHEN c.card_limit IS NOT NULL THEN ', limite ' || f_brl(c.card_limit) ELSE '' END || ', aviso ' || c.alert_days || ' dia' || CASE WHEN c.alert_days <> 1 THEN 's' ELSE '' END || ' antes.', 'kb', 'none');
  END IF;

  IF act = 'card_remove' THEN
    cid := f_card_find(p_user, nm);
    IF cid IS NULL AND nm = '' THEN
      SELECT count(*) INTO n FROM fin_cards WHERE user_id = p_user AND active;
      IF n = 1 THEN SELECT id INTO cid FROM fin_cards WHERE user_id = p_user AND active; END IF;
    END IF;
    IF cid IS NULL THEN RETURN jsonb_build_object('text', 'Não achei esse cartão. Diga "meus cartões" para ver a lista.', 'kb', 'none'); END IF;
    SELECT * INTO c FROM fin_cards WHERE id = cid;
    RETURN jsonb_build_object('text', 'Apagar o cartão ' || c.name || '? Os lançamentos continuam, só perdem a ligação com o cartão, e o aviso de vencimento acaba.', 'kb', 'ex_card_del', 'rid', cid);
  END IF;

  IF act = 'card_list' THEN
    FOR r IN SELECT * FROM fin_cards WHERE user_id = p_user AND active ORDER BY name LOOP
      t := t || E'\n- ' || r.name || ': fecha dia ' || r.closing_day || ', vence dia ' || r.due_day || CASE WHEN r.card_limit IS NOT NULL THEN ', limite ' || f_brl(r.card_limit) ELSE '' END;
    END LOOP;
    IF t = '' THEN RETURN jsonb_build_object('text', 'Você ainda não tem cartões. Diga, por exemplo: "cartão Itaú fecha dia 10 vence dia 17 limite 5000".', 'kb', 'none'); END IF;
    RETURN jsonb_build_object('text', 'Seus cartões:' || t, 'kb', 'none');
  END IF;

  IF act = 'card_status' THEN
    cid := CASE WHEN nm = '' THEN NULL ELSE f_card_find(p_user, nm) END;
    IF cid IS NOT NULL THEN RETURN jsonb_build_object('text', f_card_status_text(cid), 'kb', 'none'); END IF;
    IF nm <> '' THEN
      RETURN jsonb_build_object('text', 'Não achei o cartão "' || nm || '". Diga "meus cartões" para ver a lista ou cadastre: "cartão ' || nm || ' fecha dia 10 vence dia 17 limite 5000".', 'kb', 'none');
    END IF;
    n := 0;
    FOR r IN SELECT id FROM fin_cards WHERE user_id = p_user AND active ORDER BY name LIMIT 4 LOOP
      n := n + 1; t := t || CASE WHEN n > 1 THEN E'\n\n' ELSE '' END || f_card_status_text(r.id);
    END LOOP;
    IF n = 0 THEN RETURN jsonb_build_object('text', 'Você ainda não tem cartões. Diga, por exemplo: "cartão Itaú fecha dia 10 vence dia 17 limite 5000".', 'kb', 'none'); END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'none');
  END IF;

  RETURN jsonb_build_object('text', 'Não entendi o que fazer com o cartão.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_card_action: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui mexer nos cartões agora. Tente de novo em instantes.', 'kb', 'none');
END $$;

-- liga o lancamento recem-criado (rid da resposta de f_fin_add) ao cartao; method vira 'credito'
CREATE OR REPLACE FUNCTION f_card_link(p_user bigint, p jsonb, p_res jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE hint text := nullif(btrim(coalesce(p->>'card', '')), ''); v_rid bigint; cid bigint; c fin_cards%ROWTYPE; e fin_entries%ROWTYPE; n integer; open_amt numeric; s date; en date;
BEGIN
  IF p_res IS NULL OR coalesce(p->>'kind', 'expense') = 'income' OR p_res->>'rid' IS NULL THEN RETURN p_res; END IF;
  v_rid := (p_res->>'rid')::bigint;
  IF v_rid IS NULL OR v_rid <= 0 THEN RETURN p_res; END IF;
  SELECT * INTO e FROM fin_entries WHERE id = v_rid AND user_id = p_user;
  IF NOT FOUND OR e.kind <> 'expense' OR e.status NOT IN ('paid','draft') THEN RETURN p_res; END IF;
  IF hint IS NULL THEN
    IF coalesce(p->>'method', '') <> 'credito' THEN RETURN p_res; END IF;
    SELECT count(*) INTO n FROM fin_cards WHERE user_id = p_user AND active;
    IF n <> 1 THEN RETURN p_res; END IF;
    SELECT id INTO cid FROM fin_cards WHERE user_id = p_user AND active;
  ELSE
    cid := f_card_find(p_user, hint);
    IF cid IS NULL THEN
      RETURN jsonb_set(p_res, '{text}', to_jsonb((p_res->>'text') || E'\nNão achei o cartão "' || hint || '"; lancei sem ligar a um cartão. Cadastre com: "cartão ' || hint || ' fecha dia 10 vence dia 17 limite 5000".'));
    END IF;
  END IF;
  SELECT * INTO c FROM fin_cards WHERE id = cid;
  UPDATE fin_entries SET card_id = cid, method = 'credito'
   WHERE user_id = p_user AND (id = v_rid OR (e.series_id IS NOT NULL AND series_id = e.series_id));
  s := f_card_close_le(c.closing_day, f_fin_today(p_user)); en := f_card_close_gt(c.closing_day, f_fin_today(p_user));
  open_amt := f_card_sum(cid, s, en);
  RETURN jsonb_set(p_res, '{text}', to_jsonb((p_res->>'text') || E'\nNo cartão ' || c.name || '. Fatura aberta: ' || f_brl(open_amt) || ' (fecha ' || to_char(en, 'DD/MM') || ').'));
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_card_link: %', SQLERRM;
  RETURN p_res;
END $$;

-- ============================================================ 7. f_fin (versao viva + cartoes + consultas novas)
CREATE OR REPLACE FUNCTION f_fin(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE act text := coalesce(p->>'action', ''); res jsonb; intro boolean; d integer;
BEGIN
  PERFORM f_fin_seed(p_user);
  IF act = 'add' THEN res := f_card_link(p_user, p, f_fin_add(p_user, p));
  ELSIF act = 'pay' THEN res := f_fin_pay(p_user, p);
  ELSIF act = 'correct' THEN res := f_fin_correct(p_user, p);
  ELSIF act = 'remove' THEN res := f_fin_remove(p_user, p);
  ELSIF act IN ('summary', 'compare', 'top', 'by_day') THEN res := f_fin_report(p_user, p);
  ELSIF act IN ('budget_set', 'budget_status') THEN res := f_fin_budget(p_user, p);
  ELSIF act IN ('category_create', 'category_list') THEN res := f_fin_category(p_user, p);
  ELSIF act = 'closing_set' THEN res := f_fin_closing(p_user, p);
  ELSIF act = 'owed' THEN res := f_fin_owed(p_user, p);
  ELSIF act IN ('limit_set', 'limit_status', 'limit_clear', 'income_set', 'plan_status', 'goal_create', 'goal_deposit', 'goal_withdraw', 'goal_status', 'goal_edit', 'goal_remove') THEN res := f_fin_plan(p_user, p);
  ELSIF act IN ('card_create', 'card_edit', 'card_remove', 'card_list', 'card_status') THEN res := f_card_action(p_user, p);
  ELSIF act IN ('category_total', 'method_total', 'left_to_close', 'committed') THEN res := f_fin_query(p_user, p);
  ELSE res := jsonb_build_object('text', coalesce(nullif(p->>'reply', ''), 'Não entendi o que fazer com o dinheiro. Exemplos: "gastei 42 no mercado", "quanto gastei esse mês?", "orçamento de lazer 300".'), 'kb', 'none');
  END IF;
  SELECT fin_intro_done, fin_closing_day INTO intro, d FROM users WHERE id = p_user;
  IF NOT intro AND act IN ('add', 'summary', 'budget_set', 'budget_status') THEN
    UPDATE users SET fin_intro_done = true WHERE id = p_user;
    res := jsonb_set(res, '{text}', to_jsonb((res->>'text') || E'\n\nDica: seu mês financeiro fecha no dia ' || d || ' (diga "fecha dia 10" para mudar). Quer um orçamento? Ex.: "orçamento de mercado 800".'));
  END IF;
  RETURN res;
END $$;

-- ============================================================ 8. callbacks ex* (cartoes)
CREATE OR REPLACE FUNCTION f_extras_cb(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint; c fin_cards%ROWTYPE;
BEGIN
  BEGIN v_id := nullif(split_part(p_data, ':', 2), '')::bigint; EXCEPTION WHEN others THEN v_id := NULL; END;
  IF a = 'exkeep' THEN RETURN jsonb_build_object('text', 'Ok, mantive o cartão.', 'kb', 'none'); END IF;
  IF a = 'exdel' THEN
    SELECT * INTO c FROM fin_cards WHERE id = v_id AND user_id = p_user;
    IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Esse cartão já foi apagado.', 'kb', 'none'); END IF;
    UPDATE notifications SET state = 'cancelled' WHERE state = 'pending' AND reminder_id IN (SELECT id FROM reminders WHERE card_id = c.id AND status = 'pending');
    UPDATE reminders SET status = 'cancelled', repeat_rule = NULL WHERE card_id = c.id AND status = 'pending';
    DELETE FROM fin_cards WHERE id = c.id;
    RETURN jsonb_build_object('text', 'Apaguei o cartão ' || c.name || '. Os lançamentos continuam registrados.', 'kb', 'none');
  END IF;
  RETURN jsonb_build_object('text', 'Não entendi esse botão.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_extras_cb: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui agora. Tente de novo.', 'kb', 'none');
END $$;

-- ============================================================ 9. pequenos extras (misc_query)
CREATE OR REPLACE FUNCTION f_misc(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE kind text := coalesce(p->>'kind', ''); q text := f_norm(p->>'title'); toks text[]; tz text; t text := ''; r record; k integer := 0; n integer; nxt timestamptz; ttl text;
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  IF kind = 'calendar_link' THEN
    RETURN jsonb_build_object('text', 'Aqui está o seu Google Agenda (abre o Google Agenda): https://calendar.google.com/calendar/u/0/r', 'kb', 'none');
  END IF;
  IF kind = 'reminder_history' THEN
    SELECT array_agg(x) INTO toks FROM unnest(string_to_array(q, ' ')) x
     WHERE length(x) >= 3 AND x NOT IN ('que','com','pra','para','dos','das','meu','minha','voce','aviso','avisou','avisar','lembrete','sobre','vc');
    IF toks IS NULL THEN
      RETURN jsonb_build_object('text', 'Sobre qual lembrete? Ex.: "você me avisou da conta de luz?".', 'kb', 'none');
    END IF;
    FOR r IN
      SELECT n.sent_at, n.type, rm.title, rm.due_at FROM notifications n JOIN reminders rm ON rm.id = n.reminder_id
      WHERE n.user_id = p_user AND n.state = 'sent' AND n.sent_at > now() - interval '120 days'
        AND (SELECT bool_and(f_norm(rm.title) LIKE '%' || x || '%') FROM unnest(toks) x)
      ORDER BY n.sent_at DESC LIMIT 5
    LOOP
      k := k + 1;
      t := t || E'\n- ' || r.title || ': ' || CASE r.type WHEN 'pre_alert' THEN 'pré-aviso' WHEN 'repeat' THEN 'repetição' ELSE 'lembrete' END || ' enviado em ' || to_char(r.sent_at AT TIME ZONE tz, 'DD/MM "às" HH24:MI');
    END LOOP;
    IF k > 0 THEN RETURN jsonb_build_object('text', 'Sim, já te avisei:' || t, 'kb', 'none'); END IF;
    SELECT rm.title, n.fire_at INTO ttl, nxt FROM reminders rm JOIN notifications n ON n.reminder_id = rm.id AND n.state = 'pending'
     WHERE rm.user_id = p_user AND rm.status = 'pending' AND (SELECT bool_and(f_norm(rm.title) LIKE '%' || x || '%') FROM unnest(toks) x)
     ORDER BY n.fire_at LIMIT 1;
    IF ttl IS NOT NULL THEN
      RETURN jsonb_build_object('text', 'Ainda não te avisei. O lembrete "' || ttl || '" está agendado para ' || to_char(nxt AT TIME ZONE tz, 'DD/MM "às" HH24:MI') || '.', 'kb', 'none');
    END IF;
    SELECT count(*) INTO n FROM reminders rm WHERE rm.user_id = p_user AND (SELECT bool_and(f_norm(rm.title) LIKE '%' || x || '%') FROM unnest(toks) x);
    IF n > 0 THEN RETURN jsonb_build_object('text', 'Achei o lembrete, mas não tenho registro de aviso enviado nos últimos 120 dias.', 'kb', 'none'); END IF;
    RETURN jsonb_build_object('text', 'Não achei nenhum lembrete parecido com "' || btrim(p->>'title') || '", então não tenho registro de aviso.', 'kb', 'none');
  END IF;
  RETURN jsonb_build_object('text', 'Não entendi essa consulta.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_misc: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui consultar agora. Tente de novo.', 'kb', 'none');
END $$;

-- ============================================================ 10. resumo da manha: campo novo 'cards' (fatura fechada vencendo em ate 3 dias); demais campos intactos
CREATE OR REPLACE FUNCTION f_summary_data(p_user bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'agente', 'public'
AS $$
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
        WHERE c.user_id = p_user AND c.kind = 'expense' AND c.budget IS NOT NULL AND s.sp / c.budget >= 0.8), '[]'::jsonb),
    'cards', COALESCE((SELECT jsonb_agg(q.x ORDER BY (q.x->>'days')::int) FROM (SELECT f_card_due_info(fc.id) AS x FROM fin_cards fc WHERE fc.user_id = p_user AND fc.active) q WHERE q.x IS NOT NULL), '[]'::jsonb)
  ) INTO v;
  RETURN v;
END $$;

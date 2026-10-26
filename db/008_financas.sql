-- 008: modulo de financas (gastos, receitas, contas a pagar, parcelas, recorrencias, categorias, orcamento, relatorios)
-- Cada pessoa tem suas proprias financas (isolamento por user_id). Nada e compartilhado.
SET search_path = agente, public;

ALTER TABLE users ADD COLUMN IF NOT EXISTS fin_closing_day integer NOT NULL DEFAULT 5;
ALTER TABLE users ADD COLUMN IF NOT EXISTS fin_intro_done boolean NOT NULL DEFAULT false;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_fin_closing_day_chk') THEN
    ALTER TABLE users ADD CONSTRAINT users_fin_closing_day_chk CHECK (fin_closing_day BETWEEN 1 AND 28);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS fin_categories (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('expense', 'income')),
  keywords   text[] NOT NULL DEFAULT '{}',
  budget     numeric(12,2) CHECK (budget IS NULL OR budget > 0),
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS fin_categories_uq ON fin_categories (user_id, kind, lower(name));

CREATE TABLE IF NOT EXISTS fin_recurring (
  id                bigserial PRIMARY KEY,
  user_id           bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN ('expense', 'income')),
  amount            numeric(12,2) NOT NULL CHECK (amount > 0),
  description       text NOT NULL,
  category_id       bigint REFERENCES fin_categories(id) ON DELETE SET NULL,
  method            text,
  day_of_month      integer NOT NULL CHECK (day_of_month BETWEEN 1 AND 31),
  person            text,
  active            boolean NOT NULL DEFAULT true,
  last_generated_on date,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS fin_entries (
  id             bigserial PRIMARY KEY,
  user_id        bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind           text NOT NULL CHECK (kind IN ('expense', 'income')),
  amount         numeric(12,2) NOT NULL CHECK (amount > 0),
  description    text NOT NULL,
  norm_desc      text NOT NULL,
  category_id    bigint REFERENCES fin_categories(id) ON DELETE SET NULL,
  method         text CHECK (method IN ('pix', 'debito', 'credito', 'dinheiro', 'boleto', 'outro')),
  status         text NOT NULL DEFAULT 'paid' CHECK (status IN ('paid', 'pending', 'draft')),
  occurred_on    date NOT NULL DEFAULT CURRENT_DATE,
  due_on         date,
  paid_on        date,
  person         text,
  installment_no integer,
  installments   integer,
  series_id      uuid,
  recurring_id   bigint REFERENCES fin_recurring(id) ON DELETE SET NULL,
  reminder_id    bigint REFERENCES reminders(id) ON DELETE SET NULL,
  source         text NOT NULL DEFAULT 'text',
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fin_entries_user_date ON fin_entries (user_id, occurred_on);
CREATE INDEX IF NOT EXISTS fin_entries_user_status ON fin_entries (user_id, status);
CREATE INDEX IF NOT EXISTS fin_entries_reminder ON fin_entries (reminder_id);

-- ---------------------------------------------------------------- utilidades
CREATE OR REPLACE FUNCTION f_norm(p text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = agente, public AS $$
  SELECT btrim(regexp_replace(lower(regexp_replace(translate(coalesce(p, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc'), '[^[:alnum:] ]', '', 'g')), '[ ]+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION f_brl(p numeric) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = agente, public AS $$
  SELECT 'R$ ' || translate(to_char(coalesce(p, 0), 'FM999,999,999,990.00'), ',.', '.,')
$$;

CREATE OR REPLACE FUNCTION f_safe_date(p text) RETURNS date LANGUAGE plpgsql IMMUTABLE SET search_path = agente, public AS $$
BEGIN
  IF p IS NULL OR p = '' THEN RETURN NULL; END IF;
  RETURN p::date;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION f_fin_today(p_user bigint) RETURNS date LANGUAGE sql STABLE SET search_path = agente, public AS $$
  SELECT (now() AT TIME ZONE timezone)::date FROM users WHERE id = p_user
$$;

-- periodo financeiro: do dia de fechamento ate a vespera do proximo. offset 0 = atual, -1 = anterior.
CREATE OR REPLACE FUNCTION f_fin_period(p_user bigint, p_offset integer DEFAULT 0, OUT p_start date, OUT p_end date)
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE d integer; today date; base date;
BEGIN
  SELECT fin_closing_day INTO d FROM users WHERE id = p_user;
  today := f_fin_today(p_user);
  IF extract(day FROM today) >= d THEN base := date_trunc('month', today)::date + (d - 1);
  ELSE base := (date_trunc('month', today) - interval '1 month')::date + (d - 1);
  END IF;
  p_start := (base + make_interval(months => p_offset))::date;
  p_end := ((p_start + interval '1 month')::date) - 1;
END $$;

CREATE OR REPLACE FUNCTION f_fin_next_due(p_day integer, p_from date) RETURNS date LANGUAGE plpgsql IMMUTABLE SET search_path = agente, public AS $$
DECLARE m date := date_trunc('month', p_from)::date; d1 date; last1 integer;
BEGIN
  last1 := extract(day FROM (m + interval '1 month' - interval '1 day'))::int;
  d1 := m + (least(p_day, last1) - 1);
  IF d1 >= p_from THEN RETURN d1; END IF;
  m := (m + interval '1 month')::date;
  last1 := extract(day FROM (m + interval '1 month' - interval '1 day'))::int;
  RETURN m + (least(p_day, last1) - 1);
END $$;

CREATE OR REPLACE FUNCTION f_fin_seed(p_user bigint) RETURNS void LANGUAGE plpgsql SET search_path = agente, public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM fin_categories WHERE user_id = p_user) THEN RETURN; END IF;
  INSERT INTO fin_categories (user_id, name, kind, keywords, is_default) VALUES
    (p_user, 'Alimentação', 'expense', ARRAY['ifood','restaurante','lanche','pizza','almoco','jantar','cafe','padaria','hamburguer','sorvete','acai','comida'], true),
    (p_user, 'Mercado', 'expense', ARRAY['mercado','supermercado','feira','atacadao','hortifruti','acougue'], true),
    (p_user, 'Transporte', 'expense', ARRAY['uber','99','gasolina','combustivel','onibus','metro','estacionamento','pedagio','taxi','passagem'], true),
    (p_user, 'Moradia', 'expense', ARRAY['aluguel','condominio','luz','energia','agua','internet','gas','iptu','reforma','claro','vivo','tim','telefone','celular'], true),
    (p_user, 'Saúde', 'expense', ARRAY['farmacia','remedio','consulta','dentista','plano de saude','exame','psicologo','academia'], true),
    (p_user, 'Lazer', 'expense', ARRAY['cinema','bar','show','viagem','balada','jogo','passeio','festa'], true),
    (p_user, 'Educação', 'expense', ARRAY['curso','escola','faculdade','livro','mensalidade','material escolar'], true),
    (p_user, 'Assinaturas', 'expense', ARRAY['netflix','spotify','assinatura','icloud','youtube','prime','disney','hbo'], true),
    (p_user, 'Compras', 'expense', ARRAY['roupa','tenis','amazon','shopee','mercado livre','loja','presente','eletronico'], true),
    (p_user, 'Outros', 'expense', ARRAY[]::text[], true),
    (p_user, 'Recebimentos', 'income', ARRAY['recebi','pix recebido','reembolso','freela','freelance'], true),
    (p_user, 'Salário', 'income', ARRAY['salario','pagamento','holerite'], true)
  ON CONFLICT DO NOTHING;
END $$;

-- acha categoria por nome ou palavra-chave; NULL se nao achar
CREATE OR REPLACE FUNCTION f_fin_cat_find(p_user bigint, p_kind text, p_hint text, p_norm text) RETURNS bigint
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE v bigint; h text := f_norm(p_hint);
BEGIN
  IF h <> '' THEN
    SELECT id INTO v FROM fin_categories WHERE user_id = p_user AND kind = p_kind AND f_norm(name) = h LIMIT 1;
    IF v IS NOT NULL THEN RETURN v; END IF;
    SELECT c.id INTO v FROM fin_categories c WHERE c.user_id = p_user AND c.kind = p_kind
      AND EXISTS (SELECT 1 FROM unnest(c.keywords) k WHERE k <> '' AND (h = f_norm(k) OR h LIKE '%' || f_norm(k) || '%')) LIMIT 1;
    IF v IS NOT NULL THEN RETURN v; END IF;
  END IF;
  IF coalesce(p_norm, '') <> '' THEN
    SELECT c.id INTO v FROM fin_categories c WHERE c.user_id = p_user AND c.kind = p_kind
      AND EXISTS (SELECT 1 FROM unnest(c.keywords) k WHERE k <> '' AND p_norm LIKE '%' || f_norm(k) || '%')
    ORDER BY c.is_default LIMIT 1;
  END IF;
  RETURN v;
END $$;

-- escolhe a categoria de um lancamento: dita pelo usuario > historico da mesma descricao > palpite/palavra-chave > Outros
CREATE OR REPLACE FUNCTION f_fin_cat(p_user bigint, p_kind text, p_hint text, p_norm text, p_stated boolean) RETURNS bigint
LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE v bigint;
BEGIN
  PERFORM f_fin_seed(p_user);
  IF p_stated THEN
    v := f_fin_cat_find(p_user, p_kind, p_hint, '');
    IF v IS NOT NULL THEN RETURN v; END IF;
  END IF;
  IF coalesce(p_norm, '') <> '' THEN
    SELECT category_id INTO v FROM fin_entries
    WHERE user_id = p_user AND kind = p_kind AND norm_desc = p_norm AND category_id IS NOT NULL AND status <> 'draft'
    ORDER BY id DESC LIMIT 1;
    IF v IS NOT NULL THEN RETURN v; END IF;
  END IF;
  v := f_fin_cat_find(p_user, p_kind, p_hint, p_norm);
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT id INTO v FROM fin_categories WHERE user_id = p_user AND kind = p_kind
    AND lower(name) = CASE WHEN p_kind = 'income' THEN 'recebimentos' ELSE 'outros' END;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION f_fin_spent(p_user bigint, p_cat bigint, p_start date, p_end date) RETURNS numeric
LANGUAGE sql STABLE SET search_path = agente, public AS $$
  SELECT coalesce(sum(amount), 0) FROM fin_entries
  WHERE user_id = p_user AND category_id = p_cat AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN p_start AND p_end
$$;

-- aviso de orcamento a 80% e 100% (so quando o lancamento faz cruzar o limite)
CREATE OR REPLACE FUNCTION f_fin_budget_note(p_user bigint, p_cat bigint, p_added numeric, p_on date) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE c fin_categories%ROWTYPE; ps date; pe date; after numeric; before numeric; pa numeric; pb numeric;
BEGIN
  SELECT * INTO c FROM fin_categories WHERE id = p_cat AND user_id = p_user;
  IF NOT FOUND OR c.budget IS NULL OR c.kind <> 'expense' THEN RETURN ''; END IF;
  SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, 0);
  IF p_on NOT BETWEEN ps AND pe THEN RETURN ''; END IF;
  after := f_fin_spent(p_user, p_cat, ps, pe);
  before := after - p_added;
  pa := after / c.budget * 100; pb := before / c.budget * 100;
  IF pa >= 100 AND pb < 100 THEN
    RETURN E'\nAtenção: você passou o orçamento de ' || c.name || ': ' || f_brl(after) || ' de ' || f_brl(c.budget) || ' (' || round(pa) || '%).';
  ELSIF pa >= 80 AND pb < 80 THEN
    RETURN E'\nAtenção: ' || c.name || ' já está em ' || round(pa) || '% do orçamento (' || f_brl(after) || ' de ' || f_brl(c.budget) || ').';
  END IF;
  RETURN '';
END $$;

-- cria lembrete (Feito / Adiar) para conta pendente no dia do vencimento, 9h
CREATE OR REPLACE FUNCTION f_fin_remind(p_entry bigint) RETURNS void LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE e fin_entries%ROWTYPE; tz text; ts timestamptz; v_rid bigint; v_title text;
BEGIN
  SELECT * INTO e FROM fin_entries WHERE id = p_entry;
  IF NOT FOUND OR e.status <> 'pending' OR e.due_on IS NULL OR e.reminder_id IS NOT NULL THEN RETURN; END IF;
  SELECT timezone INTO tz FROM users WHERE id = e.user_id;
  ts := (e.due_on + time '09:00') AT TIME ZONE tz;
  IF ts < now() THEN ts := now() + interval '1 minute'; END IF;
  v_title := CASE
    WHEN e.kind = 'expense' THEN 'Pagar ' || e.description || ' (' || f_brl(e.amount) || ')'
    WHEN e.person IS NOT NULL THEN 'Cobrar ' || e.person || ': ' || f_brl(e.amount)
    ELSE 'Receber ' || e.description || ' (' || f_brl(e.amount) || ')' END;
  INSERT INTO reminders (user_id, kind, title, due_at, status, source) VALUES (e.user_id, 'reminder', v_title, ts, 'pending', 'text')
  RETURNING id INTO v_rid;
  INSERT INTO notifications (user_id, reminder_id, type, fire_at) VALUES (e.user_id, v_rid, 'reminder', ts);
  UPDATE fin_entries SET reminder_id = v_rid WHERE id = p_entry;
END $$;

-- gera a proxima ocorrencia de uma conta recorrente
CREATE OR REPLACE FUNCTION f_fin_gen(p_rec bigint) RETURNS bigint LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE r fin_recurring%ROWTYPE; v_due date; v_id bigint;
BEGIN
  SELECT * INTO r FROM fin_recurring WHERE id = p_rec AND active;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_due := f_fin_next_due(r.day_of_month, coalesce(r.last_generated_on + 1, f_fin_today(r.user_id)));
  INSERT INTO fin_entries (user_id, kind, amount, description, norm_desc, category_id, method, status, occurred_on, due_on, person, recurring_id, source)
  VALUES (r.user_id, r.kind, r.amount, r.description, f_norm(r.description), r.category_id, r.method, 'pending', v_due, v_due, r.person, r.id, 'recurring')
  RETURNING id INTO v_id;
  UPDATE fin_recurring SET last_generated_on = v_due WHERE id = p_rec;
  PERFORM f_fin_remind(v_id);
  RETURN v_id;
END $$;

-- chamada a cada minuto pelo Disparador (dentro de f_claim_due): gera a proxima conta quando a atual ja venceu
CREATE OR REPLACE FUNCTION f_fin_materialize() RETURNS void LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM fin_recurring WHERE active AND (last_generated_on IS NULL OR last_generated_on <= f_fin_today(user_id)) LOOP
    PERFORM f_fin_gen(r.id);
  END LOOP;
END $$;

-- ---------------------------------------------------------------- registrar
CREATE OR REPLACE FUNCTION f_fin_add(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE
  today date := f_fin_today(p_user);
  v_kind text := CASE WHEN p->>'kind' = 'income' THEN 'income' ELSE 'expense' END;
  v_amt numeric := round(nullif(p->>'amount', '')::numeric, 2);
  v_title text := left(btrim(coalesce(p->>'title', '')), 120);
  v_norm text; v_cat bigint; v_catname text;
  v_method text := nullif(p->>'method', '');
  n integer := least(greatest(coalesce(nullif(p->>'installments', '')::int, 1), 1), 36);
  v_paid boolean := coalesce((p->>'paid')::boolean, true);
  d date := coalesce(f_safe_date(p->>'date'), today);
  rday integer := nullif(p->>'recurring_day', '')::int;
  v_person text := nullif(btrim(coalesce(p->>'person', '')), '');
  v_src text := coalesce(p->>'source', 'text');
  v_id bigint; v_first bigint; v_rec bigint; v_series uuid; i integer; v_txt text; v_label text;
BEGIN
  IF v_amt IS NULL OR v_amt <= 0 THEN
    RETURN jsonb_build_object('text', 'Qual foi o valor? Me diga o valor para eu registrar.', 'kb', 'none');
  END IF;
  IF v_title = '' THEN v_title := CASE WHEN v_kind = 'income' THEN 'Recebimento' ELSE 'Gasto' END; END IF;
  IF v_method IS NOT NULL AND v_method NOT IN ('pix', 'debito', 'credito', 'dinheiro', 'boleto') THEN v_method := NULL; END IF;
  v_norm := f_norm(v_title);
  v_cat := f_fin_cat(p_user, v_kind, p->>'category', v_norm, coalesce((p->>'category_stated')::boolean, false));
  SELECT name INTO v_catname FROM fin_categories WHERE id = v_cat;
  v_label := CASE WHEN v_kind = 'income' THEN 'receita' ELSE 'gasto' END;

  -- conta ou receita que se repete todo mes
  IF rday IS NOT NULL AND rday BETWEEN 1 AND 31 THEN
    INSERT INTO fin_recurring (user_id, kind, amount, description, category_id, method, day_of_month, person)
    VALUES (p_user, v_kind, v_amt, v_title, v_cat, v_method, rday, v_person) RETURNING id INTO v_rec;
    v_id := f_fin_gen(v_rec);
    SELECT due_on INTO d FROM fin_entries WHERE id = v_id;
    RETURN jsonb_build_object('text', 'Anotei ' || CASE WHEN v_kind = 'income' THEN 'a receita' ELSE 'a conta' END || ' fixa: ' || v_title || ' ' || f_brl(v_amt) ||
      ' todo dia ' || rday || ' (' || v_catname || '). Próximo vencimento: ' || to_char(d, 'DD/MM') ||
      '. Te aviso no dia e você toca Feito quando ' || CASE WHEN v_kind = 'income' THEN 'receber.' ELSE 'pagar.' END, 'kb', 'fin_undo', 'rid', v_id);
  END IF;

  -- compra parcelada: cada parcela entra no mes dela
  IF n > 1 THEN
    v_series := gen_random_uuid();
    FOR i IN 1..n LOOP
      INSERT INTO fin_entries (user_id, kind, amount, description, norm_desc, category_id, method, status, occurred_on, paid_on, person, installment_no, installments, series_id, source)
      VALUES (p_user, v_kind, v_amt, v_title, v_norm, v_cat, coalesce(v_method, 'credito'), 'paid', (d + make_interval(months => i - 1))::date, (d + make_interval(months => i - 1))::date, v_person, i, n, v_series, v_src)
      RETURNING id INTO v_id;
      IF i = 1 THEN v_first := v_id; END IF;
    END LOOP;
    RETURN jsonb_build_object('text', 'Registrei: ' || v_title || ' em ' || n || 'x de ' || f_brl(v_amt) || ' (total ' || f_brl(v_amt * n) || '), categoria ' || v_catname ||
      '. As parcelas entram mês a mês, a primeira em ' || to_char(d, 'DD/MM') || '.' || f_fin_budget_note(p_user, v_cat, v_amt, d), 'kb', 'fin_undo', 'rid', v_first);
  END IF;

  -- foto ou arquivo (recibo, boleto): confirma antes de gravar; se for conta a pagar, guarda o vencimento no rascunho
  IF v_src = 'photo' THEN
    INSERT INTO fin_entries (user_id, kind, amount, description, norm_desc, category_id, method, status, occurred_on, due_on, person, source)
    VALUES (p_user, v_kind, v_amt, v_title, v_norm, v_cat, v_method, 'draft', d, CASE WHEN NOT v_paid THEN d END, v_person, v_src) RETURNING id INTO v_id;
    IF v_paid THEN
      RETURN jsonb_build_object('text', 'Li no documento: ' || f_brl(v_amt) || ' em "' || v_title || '", categoria ' || v_catname || ', data ' || to_char(d, 'DD/MM') ||
        '. Confirma?', 'kb', 'fin_confirm', 'rid', v_id);
    END IF;
    RETURN jsonb_build_object('text', 'Li no documento: conta de ' || f_brl(v_amt) || ' "' || v_title || '", vence ' || to_char(d, 'DD/MM') || ', categoria ' || v_catname ||
      '. Anoto como a pagar e te aviso no dia. Confirma?', 'kb', 'fin_confirm', 'rid', v_id);
  END IF;

  -- conta a pagar / receita a receber / alguem te deve
  IF NOT v_paid THEN
    INSERT INTO fin_entries (user_id, kind, amount, description, norm_desc, category_id, method, status, occurred_on, due_on, person, source)
    VALUES (p_user, v_kind, v_amt, v_title, v_norm, v_cat, v_method, 'pending', d, d, v_person, v_src) RETURNING id INTO v_id;
    PERFORM f_fin_remind(v_id);
    IF v_kind = 'income' AND v_person IS NOT NULL THEN
      v_txt := 'Anotei: ' || v_person || ' te deve ' || f_brl(v_amt) || ' (' || v_title || ', desde ' || to_char(d, 'DD/MM') || '). Quando pagar, diga "' || v_person || ' pagou".';
    ELSIF v_kind = 'income' THEN
      v_txt := 'Anotei a receber: ' || v_title || ' ' || f_brl(v_amt) || ', previsto para ' || to_char(d, 'DD/MM') || '. Te aviso no dia.';
    ELSE
      v_txt := 'Anotei a pagar: ' || v_title || ' ' || f_brl(v_amt) || ', vence ' || to_char(d, 'DD/MM') || ' (' || v_catname || '). Te aviso no dia; depois é só tocar Feito ou dizer "já paguei".';
    END IF;
    RETURN jsonb_build_object('text', v_txt, 'kb', 'fin_undo', 'rid', v_id);
  END IF;

  -- lancamento simples ja pago
  INSERT INTO fin_entries (user_id, kind, amount, description, norm_desc, category_id, method, status, occurred_on, paid_on, person, source)
  VALUES (p_user, v_kind, v_amt, v_title, v_norm, v_cat, v_method, 'paid', d, d, v_person, v_src) RETURNING id INTO v_id;
  RETURN jsonb_build_object('text', 'Registrei: ' || v_label || ' de ' || f_brl(v_amt) || ' em ' || v_title || ' (' || v_catname || ')' ||
    CASE WHEN v_method IS NOT NULL THEN ', ' || v_method ELSE '' END ||
    CASE WHEN d <> today THEN ', ' || to_char(d, 'DD/MM') ELSE '' END || '.' ||
    CASE WHEN v_kind = 'expense' THEN f_fin_budget_note(p_user, v_cat, v_amt, d) ELSE '' END, 'kb', 'fin_undo', 'rid', v_id);
END $$;

-- ---------------------------------------------------------------- baixar, corrigir, apagar
CREATE OR REPLACE FUNCTION f_fin_pay(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE today date := f_fin_today(p_user); q text := f_norm(p->>'title'); e fin_entries%ROWTYPE;
BEGIN
  SELECT * INTO e FROM fin_entries
  WHERE user_id = p_user AND status = 'pending'
    AND (q = '' OR norm_desc LIKE '%' || q || '%' OR f_norm(person) LIKE '%' || q || '%')
  ORDER BY (due_on < today) DESC, due_on, id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('text', CASE WHEN q = '' THEN 'Não tenho nenhuma conta ou cobrança pendente anotada.'
      ELSE 'Não achei "' || btrim(p->>'title') || '" entre as pendentes. Diga "o que tenho a pagar" para ver a lista.' END, 'kb', 'none');
  END IF;
  UPDATE fin_entries SET status = 'paid', paid_on = today, occurred_on = today WHERE id = e.id;
  IF e.reminder_id IS NOT NULL THEN
    UPDATE reminders SET status = 'done' WHERE id = e.reminder_id;
    UPDATE notifications SET state = 'cancelled' WHERE reminder_id = e.reminder_id AND state = 'pending';
  END IF;
  RETURN jsonb_build_object('text', CASE WHEN e.kind = 'income' THEN 'Recebido: ' ELSE 'Pago: ' END || e.description || ' ' || f_brl(e.amount) ||
    CASE WHEN e.due_on < today THEN ' (vencia em ' || to_char(e.due_on, 'DD/MM') || ')' ELSE '' END || '.', 'kb', 'none');
END $$;

CREATE OR REPLACE FUNCTION f_fin_correct(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE e fin_entries%ROWTYPE; v_amt numeric := round(nullif(p->>'amount', '')::numeric, 2); v_cat bigint; v_name text; v_title text := btrim(coalesce(p->>'title', ''));
        v_hint text := btrim(coalesce(p->>'category', '')); v_changes text[] := '{}'; v_found boolean := false;
BEGIN
  -- alvo: o lancamento citado pelo nome (se houver) ou o ultimo
  IF v_title <> '' THEN
    SELECT * INTO e FROM fin_entries WHERE user_id = p_user AND status <> 'draft' AND norm_desc LIKE '%' || f_norm(v_title) || '%' ORDER BY id DESC LIMIT 1;
    v_found := FOUND;
  END IF;
  IF NOT v_found THEN
    SELECT * INTO e FROM fin_entries WHERE user_id = p_user AND status <> 'draft' ORDER BY id DESC LIMIT 1;
  END IF;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não tenho nenhum lançamento para corrigir.', 'kb', 'none'); END IF;
  IF v_amt IS NOT NULL AND v_amt > 0 THEN
    UPDATE fin_entries SET amount = v_amt WHERE id = e.id; v_changes := v_changes || ('valor ' || f_brl(v_amt));
  END IF;
  IF v_hint <> '' THEN
    v_cat := f_fin_cat_find(p_user, e.kind, v_hint, '');
    IF v_cat IS NULL THEN
      INSERT INTO fin_categories (user_id, name, kind) VALUES (p_user, left(v_hint, 60), e.kind) ON CONFLICT DO NOTHING;
      v_cat := f_fin_cat_find(p_user, e.kind, v_hint, '');
    END IF;
    IF v_cat IS NOT NULL THEN
      UPDATE fin_entries SET category_id = v_cat WHERE id = e.id OR (e.series_id IS NOT NULL AND series_id = e.series_id);
      SELECT name INTO v_name FROM fin_categories WHERE id = v_cat; v_changes := v_changes || ('categoria ' || v_name);
    END IF;
  END IF;
  IF v_title <> '' AND NOT v_found AND f_norm(v_title) <> e.norm_desc AND v_hint = '' AND v_amt IS NULL THEN
    UPDATE fin_entries SET description = left(v_title, 120), norm_desc = f_norm(v_title) WHERE id = e.id; v_changes := v_changes || ('descrição ' || v_title);
  END IF;
  IF array_length(v_changes, 1) IS NULL THEN
    RETURN jsonb_build_object('text', 'O que devo corrigir em ' || e.description || ' ' || f_brl(e.amount) || '? Valor, categoria ou descrição?', 'kb', 'none');
  END IF;
  RETURN jsonb_build_object('text', 'Corrigido: ' || e.description || ' agora com ' || array_to_string(v_changes, ', ') || '.', 'kb', 'none');
END $$;

CREATE OR REPLACE FUNCTION f_fin_remove(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE q text := f_norm(p->>'title'); e fin_entries%ROWTYPE;
BEGIN
  SELECT * INTO e FROM fin_entries WHERE user_id = p_user AND status <> 'draft' AND (q = '' OR norm_desc LIKE '%' || q || '%') ORDER BY id DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não achei esse lançamento.', 'kb', 'none'); END IF;
  RETURN jsonb_build_object('text', 'Apagar ' || e.description || ' ' || f_brl(e.amount) || ' (' || to_char(e.occurred_on, 'DD/MM') || ')' ||
    CASE WHEN e.series_id IS NOT NULL THEN ' e as outras parcelas' ELSE '' END || '?', 'kb', 'fin_delete', 'rid', e.id);
END $$;

CREATE OR REPLACE FUNCTION f_fin_cb(p_user bigint, p_action text, p_id bigint) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE e fin_entries%ROWTYPE; v_note text := '';
BEGIN
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

-- ---------------------------------------------------------------- consultas
CREATE OR REPLACE FUNCTION f_fin_range(p_user bigint, p_period text, OUT r_start date, OUT r_end date, OUT r_label text)
LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE today date := f_fin_today(p_user);
BEGIN
  IF p_period = 'today' THEN r_start := today; r_end := today; r_label := 'hoje';
  ELSIF p_period = 'yesterday' THEN r_start := today - 1; r_end := today - 1; r_label := 'ontem';
  ELSIF p_period = 'week' THEN r_start := today - 6; r_end := today; r_label := 'últimos 7 dias';
  ELSIF p_period = 'previous' THEN SELECT p_start, p_end INTO r_start, r_end FROM f_fin_period(p_user, -1); r_label := 'mês anterior';
  ELSE SELECT p_start, p_end INTO r_start, r_end FROM f_fin_period(p_user, 0); r_label := 'mês atual';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION f_fin_pending_text(p_user bigint) RETURNS text LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE today date := f_fin_today(p_user); t text := ''; r record; n integer := 0; tot numeric := 0; late integer := 0;
BEGIN
  FOR r IN SELECT description, amount, due_on, person, kind FROM fin_entries WHERE user_id = p_user AND status = 'pending' AND kind = 'expense' ORDER BY due_on LIMIT 8 LOOP
    n := n + 1; tot := tot + r.amount;
    IF r.due_on < today THEN late := late + 1; END IF;
    t := t || E'\n- ' || r.description || ' ' || f_brl(r.amount) || ', ' || CASE WHEN r.due_on < today THEN 'ATRASADA desde ' ELSE 'vence ' END || to_char(r.due_on, 'DD/MM');
  END LOOP;
  IF n = 0 THEN RETURN ''; END IF;
  RETURN E'\n\nA pagar (' || n || '), ' || f_brl(tot) || CASE WHEN late > 0 THEN ', ' || late || ' atrasada(s). Diga "já paguei" quando quitar' ELSE '' END || ':' || t;
END $$;

CREATE OR REPLACE FUNCTION f_fin_report(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE
  act text := coalesce(p->>'action', 'summary'); today date := f_fin_today(p_user);
  rs date; re date; lbl text; v_exp numeric; v_inc numeric; t text; r record; ps date; pe date; cs date;
  cur_total numeric; prev_same numeric; prev_full numeric; days_elapsed integer; k integer;
BEGIN
  PERFORM f_fin_seed(p_user);
  SELECT r_start, r_end, r_label INTO rs, re, lbl FROM f_fin_range(p_user, coalesce(nullif(p->>'period', ''), 'current'));

  IF act = 'compare' THEN
    SELECT p_start INTO cs FROM f_fin_period(p_user, 0);
    SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, -1);
    days_elapsed := today - cs;
    SELECT coalesce(sum(amount), 0) INTO cur_total FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN cs AND today;
    SELECT coalesce(sum(amount), 0) INTO prev_same FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN ps AND ps + days_elapsed;
    SELECT coalesce(sum(amount), 0) INTO prev_full FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN ps AND pe;
    IF cur_total = 0 AND prev_full = 0 THEN RETURN jsonb_build_object('text', 'Ainda não tenho gastos registrados nesses dois períodos para comparar.', 'kb', 'none'); END IF;
    t := 'Mês atual (' || to_char(cs, 'DD/MM') || ' a hoje): ' || f_brl(cur_total) || E'\nMês anterior, mesmo trecho (' || to_char(ps, 'DD/MM') || ' a ' || to_char(ps + days_elapsed, 'DD/MM') || '): ' || f_brl(prev_same) ||
      CASE WHEN prev_same > 0 THEN E'\nVariação: ' || CASE WHEN cur_total >= prev_same THEN '+' ELSE '' END || round((cur_total - prev_same) / prev_same * 100) || '%' ELSE '' END ||
      E'\nMês anterior fechado (' || to_char(ps, 'DD/MM') || ' a ' || to_char(pe, 'DD/MM') || '): ' || f_brl(prev_full);
    k := 0;
    FOR r IN
      SELECT c.name, coalesce(a.s, 0) AS cur, coalesce(b.s, 0) AS prev
      FROM fin_categories c
      LEFT JOIN (SELECT category_id, sum(amount) s FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN cs AND today GROUP BY 1) a ON a.category_id = c.id
      LEFT JOIN (SELECT category_id, sum(amount) s FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN ps AND ps + days_elapsed GROUP BY 1) b ON b.category_id = c.id
      WHERE c.user_id = p_user AND c.kind = 'expense' AND (coalesce(a.s, 0) > 0 OR coalesce(b.s, 0) > 0)
      ORDER BY abs(coalesce(a.s, 0) - coalesce(b.s, 0)) DESC LIMIT 5
    LOOP
      IF k = 0 THEN t := t || E'\n\nO que mais mudou:'; END IF;
      k := k + 1;
      t := t || E'\n- ' || r.name || ': ' || f_brl(r.cur) || ' (antes ' || f_brl(r.prev) || ')';
    END LOOP;
    RETURN jsonb_build_object('text', t, 'kb', 'none');
  END IF;

  IF act = 'top' THEN
    t := 'Maiores despesas (' || lbl || ', ' || to_char(rs, 'DD/MM') || ' a ' || to_char(re, 'DD/MM') || '):';
    k := 0;
    FOR r IN SELECT e.description, e.amount, e.occurred_on, c.name AS cat FROM fin_entries e LEFT JOIN fin_categories c ON c.id = e.category_id
             WHERE e.user_id = p_user AND e.kind = 'expense' AND e.status = 'paid' AND e.occurred_on BETWEEN rs AND re ORDER BY e.amount DESC LIMIT 5 LOOP
      k := k + 1; t := t || E'\n' || k || ') ' || r.description || ' ' || f_brl(r.amount) || ' (' || coalesce(r.cat, 'Outros') || ', ' || to_char(r.occurred_on, 'DD/MM') || ')';
    END LOOP;
    IF k = 0 THEN RETURN jsonb_build_object('text', 'Nenhum gasto registrado em ' || lbl || '.', 'kb', 'none'); END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'none');
  END IF;

  IF act = 'by_day' THEN
    t := 'Gastos por dia (' || lbl || ', ' || to_char(rs, 'DD/MM') || ' a ' || to_char(re, 'DD/MM') || '):';
    k := 0;
    FOR r IN SELECT occurred_on, sum(amount) s, count(*) n FROM fin_entries WHERE user_id = p_user AND kind = 'expense' AND status = 'paid' AND occurred_on BETWEEN rs AND re
             GROUP BY 1 ORDER BY 1 DESC LIMIT 15 LOOP
      k := k + 1; t := t || E'\n- ' || to_char(r.occurred_on, 'DD/MM') || ': ' || f_brl(r.s) || ' (' || r.n || ' lançamento(s))';
    END LOOP;
    IF k = 0 THEN RETURN jsonb_build_object('text', 'Nenhum gasto registrado em ' || lbl || '.', 'kb', 'none'); END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'none');
  END IF;

  -- summary
  SELECT coalesce(sum(amount) FILTER (WHERE kind = 'expense'), 0), coalesce(sum(amount) FILTER (WHERE kind = 'income'), 0) INTO v_exp, v_inc
  FROM fin_entries WHERE user_id = p_user AND status = 'paid' AND occurred_on BETWEEN rs AND re;
  t := 'Resumo (' || lbl || ', ' || to_char(rs, 'DD/MM') || ' a ' || to_char(re, 'DD/MM') || '):' ||
       E'\nGastos: ' || f_brl(v_exp) || E'\nReceitas: ' || f_brl(v_inc) || E'\nSaldo: ' || CASE WHEN v_inc - v_exp < 0 THEN '-' ELSE '' END || f_brl(abs(v_inc - v_exp));
  k := 0;
  FOR r IN SELECT coalesce(c.name, 'Outros') AS name, sum(e.amount) s, c.budget FROM fin_entries e LEFT JOIN fin_categories c ON c.id = e.category_id
           WHERE e.user_id = p_user AND e.kind = 'expense' AND e.status = 'paid' AND e.occurred_on BETWEEN rs AND re GROUP BY c.name, c.budget ORDER BY 2 DESC LIMIT 10 LOOP
    IF k = 0 THEN t := t || E'\n\nGastos por categoria:'; END IF;
    k := k + 1;
    t := t || E'\n- ' || r.name || ': ' || f_brl(r.s) || ' (' || round(r.s / v_exp * 100) || '%)' ||
         CASE WHEN r.budget IS NOT NULL THEN ', orçamento ' || f_brl(r.budget) || ' (' || round(r.s / r.budget * 100) || '%)' ELSE '' END;
  END LOOP;
  IF k = 0 AND v_inc = 0 THEN t := 'Nenhum lançamento em ' || lbl || ' (' || to_char(rs, 'DD/MM') || ' a ' || to_char(re, 'DD/MM') || '). Para começar, diga por exemplo: "gastei 42 no mercado".'; END IF;
  t := t || f_fin_pending_text(p_user);
  RETURN jsonb_build_object('text', t, 'kb', 'none');
END $$;

CREATE OR REPLACE FUNCTION f_fin_owed(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = agente, public AS $$
DECLARE t text := ''; r record; tot numeric := 0; n integer := 0;
BEGIN
  FOR r IN SELECT person, sum(amount) s, min(due_on) since FROM fin_entries WHERE user_id = p_user AND status = 'pending' AND kind = 'income' AND person IS NOT NULL GROUP BY person ORDER BY 2 DESC LOOP
    n := n + 1; tot := tot + r.s; t := t || E'\n- ' || r.person || ': ' || f_brl(r.s) || ' (desde ' || to_char(r.since, 'DD/MM') || ')';
  END LOOP;
  IF n = 0 THEN RETURN jsonb_build_object('text', 'Ninguém te deve nada anotado. Para anotar: "o João me deve 50".', 'kb', 'none'); END IF;
  RETURN jsonb_build_object('text', 'Quem te deve (' || f_brl(tot) || '):' || t || E'\nQuando pagarem, diga por exemplo "o João pagou".', 'kb', 'none');
END $$;

-- ---------------------------------------------------------------- categorias e orcamento
CREATE OR REPLACE FUNCTION f_fin_budget(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE
  act text := p->>'action'; v_hint text := btrim(coalesce(nullif(p->>'category', ''), p->>'title', '')); v_amt numeric := round(nullif(p->>'budget_amount', '')::numeric, 2);
  v_cat bigint; c fin_categories%ROWTYPE; ps date; pe date; sp numeric; t text := ''; r record; k integer := 0; left_days integer; a1 numeric; a2 numeric; n1 integer; n2 integer;
  s1 date; e1 date; s2 date; e2 date;
BEGIN
  PERFORM f_fin_seed(p_user);
  SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, 0);
  IF act = 'budget_set' THEN
    IF v_amt IS NULL OR v_amt <= 0 THEN RETURN jsonb_build_object('text', 'Qual o valor do orçamento mensal? Ex.: "orçamento de mercado 800".', 'kb', 'none'); END IF;
    IF v_hint = '' THEN RETURN jsonb_build_object('text', 'Para qual categoria? Ex.: "orçamento de mercado 800".', 'kb', 'none'); END IF;
    v_cat := f_fin_cat_find(p_user, 'expense', v_hint, '');
    IF v_cat IS NULL THEN
      INSERT INTO fin_categories (user_id, name, kind) VALUES (p_user, initcap(left(v_hint, 60)), 'expense') ON CONFLICT DO NOTHING;
      v_cat := f_fin_cat_find(p_user, 'expense', v_hint, '');
    END IF;
    UPDATE fin_categories SET budget = v_amt WHERE id = v_cat RETURNING * INTO c;
    sp := f_fin_spent(p_user, c.id, ps, pe);
    RETURN jsonb_build_object('text', 'Orçamento de ' || c.name || ': ' || f_brl(v_amt) || ' por mês (mês financeiro ' || to_char(ps, 'DD/MM') || ' a ' || to_char(pe, 'DD/MM') || '). Até agora: ' ||
      f_brl(sp) || ' (' || round(sp / v_amt * 100) || '%). Aviso quando chegar a 80% e a 100%.', 'kb', 'none');
  END IF;

  -- budget_status
  IF v_hint <> '' THEN
    v_cat := f_fin_cat_find(p_user, 'expense', v_hint, '');
    IF v_cat IS NULL THEN RETURN jsonb_build_object('text', 'Não conheço a categoria "' || v_hint || '". Diga "minhas categorias" para ver a lista.', 'kb', 'none'); END IF;
    SELECT * INTO c FROM fin_categories WHERE id = v_cat;
    sp := f_fin_spent(p_user, c.id, ps, pe);
    left_days := greatest(pe - f_fin_today(p_user) + 1, 1);
    IF c.budget IS NOT NULL THEN
      RETURN jsonb_build_object('text', c.name || ': gasto ' || f_brl(sp) || ' de ' || f_brl(c.budget) || ' (' || round(sp / c.budget * 100) || '%). ' ||
        CASE WHEN c.budget > sp THEN 'Restam ' || f_brl(c.budget - sp) || ' para ' || left_days || ' dia(s), cerca de ' || f_brl((c.budget - sp) / left_days) || ' por dia.'
             ELSE 'Passou ' || f_brl(sp - c.budget) || ' do orçamento.' END, 'kb', 'none');
    END IF;
    SELECT p_start, p_end INTO s1, e1 FROM f_fin_period(p_user, -1);
    SELECT p_start, p_end INTO s2, e2 FROM f_fin_period(p_user, -2);
    a1 := f_fin_spent(p_user, c.id, s1, e1); a2 := f_fin_spent(p_user, c.id, s2, e2);
    RETURN jsonb_build_object('text', c.name || ' ainda não tem orçamento. Gasto no mês atual: ' || f_brl(sp) || '.' ||
      CASE WHEN a1 > 0 AND a2 > 0 THEN ' Nos 2 meses anteriores você gastou em média ' || f_brl(round((a1 + a2) / 2)) || '. Para definir: "orçamento de ' || lower(c.name) || ' ' || round((a1 + a2) / 2) || '".'
           ELSE ' Para definir: "orçamento de ' || lower(c.name) || ' 500".' END, 'kb', 'none');
  END IF;
  FOR r IN SELECT name, budget, f_fin_spent(p_user, id, ps, pe) AS sp FROM fin_categories WHERE user_id = p_user AND kind = 'expense' AND budget IS NOT NULL ORDER BY name LOOP
    k := k + 1;
    t := t || E'\n- ' || r.name || ': ' || f_brl(r.sp) || ' de ' || f_brl(r.budget) || ' (' || round(r.sp / r.budget * 100) || '%)' ||
         CASE WHEN r.budget > r.sp THEN ', restam ' || f_brl(r.budget - r.sp) ELSE ', passou ' || f_brl(r.sp - r.budget) END;
  END LOOP;
  IF k = 0 THEN RETURN jsonb_build_object('text', 'Você ainda não definiu orçamentos. Ex.: "orçamento de mercado 800" ou "orçamento de lazer 300".', 'kb', 'none'); END IF;
  RETURN jsonb_build_object('text', 'Orçamentos (' || to_char(ps, 'DD/MM') || ' a ' || to_char(pe, 'DD/MM') || '):' || t, 'kb', 'none');
END $$;

CREATE OR REPLACE FUNCTION f_fin_category(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE
  act text := p->>'action'; v_kind text := CASE WHEN p->>'kind' = 'income' THEN 'income' ELSE 'expense' END;
  v_name text := btrim(coalesce(nullif(p->>'category', ''), p->>'title', '')); kws text[]; v_id bigint; t text := ''; r record; k integer := 0;
BEGIN
  PERFORM f_fin_seed(p_user);
  IF act = 'category_list' THEN
    FOR r IN SELECT name, kind, budget, keywords FROM fin_categories WHERE user_id = p_user ORDER BY kind DESC, name LOOP
      k := k + 1;
      t := t || E'\n- ' || r.name || CASE WHEN r.kind = 'income' THEN ' (receita)' ELSE '' END ||
           CASE WHEN r.budget IS NOT NULL THEN ', orçamento ' || f_brl(r.budget) ELSE '' END ||
           CASE WHEN array_length(r.keywords, 1) > 0 THEN ' [' || array_to_string(r.keywords[1:4], ', ') || ']' ELSE '' END;
    END LOOP;
    RETURN jsonb_build_object('text', 'Suas categorias:' || t || E'\nPara criar: "cria a categoria Pet com ração e veterinário".', 'kb', 'none');
  END IF;
  IF v_name = '' THEN RETURN jsonb_build_object('text', 'Qual o nome da categoria? Ex.: "cria a categoria Pet com ração e veterinário".', 'kb', 'none'); END IF;
  SELECT coalesce(array_agg(DISTINCT f_norm(x)) FILTER (WHERE f_norm(x) <> ''), '{}') INTO kws FROM unnest(string_to_array(coalesce(p->>'keywords', ''), ',')) x;
  v_id := f_fin_cat_find(p_user, v_kind, v_name, '');
  IF v_id IS NOT NULL AND EXISTS (SELECT 1 FROM fin_categories WHERE id = v_id AND f_norm(name) = f_norm(v_name)) THEN
    UPDATE fin_categories SET keywords = ARRAY(SELECT DISTINCT unnest(keywords || kws)) WHERE id = v_id;
    RETURN jsonb_build_object('text', 'A categoria ' || v_name || ' já existe' || CASE WHEN array_length(kws, 1) > 0 THEN '; acrescentei as palavras-chave: ' || array_to_string(kws, ', ') ELSE '' END || '.', 'kb', 'none');
  END IF;
  INSERT INTO fin_categories (user_id, name, kind, keywords) VALUES (p_user, left(v_name, 60), v_kind, kws) ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('text', 'Categoria criada: ' || v_name || CASE WHEN array_length(kws, 1) > 0 THEN ' (palavras-chave: ' || array_to_string(kws, ', ') || ')' ELSE '' END ||
    '. Quando um gasto citar essas palavras, eu uso essa categoria.', 'kb', 'none');
END $$;

CREATE OR REPLACE FUNCTION f_fin_closing(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
DECLARE d integer := nullif(p->>'closing_day', '')::int; ps date; pe date;
BEGIN
  IF d IS NULL OR d NOT BETWEEN 1 AND 28 THEN
    RETURN jsonb_build_object('text', 'Em que dia (1 a 28) fecha o seu mês financeiro? Ex.: "fecha dia 5".', 'kb', 'none');
  END IF;
  UPDATE users SET fin_closing_day = d, fin_intro_done = true WHERE id = p_user;
  SELECT p_start, p_end INTO ps, pe FROM f_fin_period(p_user, 0);
  RETURN jsonb_build_object('text', 'Pronto: seu mês financeiro agora fecha no dia ' || d || '. O período atual vai de ' || to_char(ps, 'DD/MM') || ' a ' || to_char(pe, 'DD/MM') || '.', 'kb', 'none');
END $$;

-- ---------------------------------------------------------------- entrada unica
CREATE OR REPLACE FUNCTION f_fin(p_user bigint, p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path = agente, public AS $$
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
  ELSE res := jsonb_build_object('text', coalesce(nullif(p->>'reply', ''), 'Não entendi o que fazer com o dinheiro. Exemplos: "gastei 42 no mercado", "quanto gastei esse mês?", "orçamento de lazer 300".'), 'kb', 'none');
  END IF;
  SELECT fin_intro_done, fin_closing_day INTO intro, d FROM users WHERE id = p_user;
  IF NOT intro AND act IN ('add', 'summary', 'budget_set', 'budget_status') THEN
    UPDATE users SET fin_intro_done = true WHERE id = p_user;
    res := jsonb_set(res, '{text}', to_jsonb((res->>'text') || E'\n\nDica: seu mês financeiro fecha no dia ' || d || ' (diga "fecha dia 10" para mudar). Quer um orçamento? Ex.: "orçamento de mercado 800".'));
  END IF;
  RETURN res;
END $$;

-- ---------------------------------------------------------------- integracao com botoes e disparador
CREATE OR REPLACE FUNCTION f_callback(p_user bigint, p_data text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'agente', 'public'
AS $function$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint := NULLIF(split_part(p_data, ':', 2), '')::bigint;
        r reminders%ROWTYPE; s supplies%ROWTYPE; tz text; v_new timestamptz; v_sid bigint; v_st supplies_status%ROWTYPE; v_fin fin_entries%ROWTYPE;
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  IF a = 'sum' THEN
    UPDATE users SET summary_time = substr(p_data, 5)::time, onboarding_step = 'done', onboarded_at = COALESCE(onboarded_at, now())
    WHERE id = p_user;
    RETURN jsonb_build_object('text', 'Pronto! Seu resumo diario sai as ' || substr(p_data, 5) ||
      '. Pode me mandar seu primeiro lembrete, por texto ou audio.', 'kb', 'none');
  ELSIF a = 'lead' THEN
    RETURN f_set_lead(p_user, v_id, split_part(p_data, ':', 3)::integer);
  ELSIF a IN ('fundo', 'fok', 'fno', 'fdel', 'fkeep') THEN
    RETURN f_fin_cb(p_user, a, v_id);
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
    UPDATE fin_entries SET status = 'paid', paid_on = f_fin_today(p_user), occurred_on = f_fin_today(p_user)
    WHERE reminder_id = v_id AND user_id = p_user AND status = 'pending' RETURNING * INTO v_fin;
    IF v_fin.id IS NOT NULL THEN
      RETURN jsonb_build_object('text', CASE WHEN v_fin.kind = 'income' THEN 'Recebido: ' ELSE 'Pago: ' END || v_fin.description || ' ' || f_brl(v_fin.amount) || '.', 'kb', 'none');
    END IF;
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
END $function$;

CREATE OR REPLACE FUNCTION f_claim_due()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'agente', 'public'
AS $function$
DECLARE v jsonb;
BEGIN
  PERFORM f_enqueue_doses();
  PERFORM f_fin_materialize();
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
END $function$;

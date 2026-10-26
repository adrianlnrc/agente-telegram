-- Fase 4, modulo N: listas de itens (mercado etc.) e notas livres.
-- Idempotente (CREATE ... IF NOT EXISTS / CREATE OR REPLACE). Sem extensoes novas (busca com f_norm + LIKE).
-- Funcoes chamadas pelo n8n: f_lists(user, jsonb), f_notes(user, jsonb), f_lists_cb(user, callback_data).
-- Todas devolvem jsonb {text, kb, rid} e nunca lancam excecao ao usuario. Todo acesso filtra por user_id.
-- Botoes: teclado 'ls_confirm' = Confirmar lsok:{rid} / Cancelar lsno:{rid} (rid = list_pending.id).
SET search_path TO agente, public;

CREATE TABLE IF NOT EXISTS lists (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  name_norm  text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS lists_user_name ON lists (user_id, name_norm);

CREATE TABLE IF NOT EXISTS list_items (
  id         bigserial PRIMARY KEY,
  list_id    bigint NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  name_norm  text NOT NULL,
  done       boolean NOT NULL DEFAULT false,
  done_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS list_items_list ON list_items (list_id, done, id);
CREATE INDEX IF NOT EXISTS list_items_user ON list_items (user_id);

CREATE TABLE IF NOT EXISTS notes (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body       text NOT NULL,
  body_norm  text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notes_user_created ON notes (user_id, created_at DESC);

-- Confirmacoes de acoes destrutivas (apagar lista, limpar lista, apagar nota).
CREATE TABLE IF NOT EXISTS list_pending (
  id          bigserial PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('delete_list','clear_list','delete_note')),
  target_id   bigint NOT NULL,
  target_name text NOT NULL DEFAULT '',
  state       text NOT NULL DEFAULT 'open' CHECK (state IN ('open','done','cancelled')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS list_pending_user ON list_pending (user_id, state);

-- ---------- auxiliares ----------
-- "lista de mercado" / "a lista da farmacia" -> "mercado" / "farmacia".
CREATE OR REPLACE FUNCTION f_ls_clean(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT btrim(regexp_replace(regexp_replace(btrim(COALESCE(p, '')),
    '^((a|o|minha|nossa) )*lista ((de|da|do|dos|das) )?', '', 'i'), '[ ]+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION f_ls_disp(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT upper(left(btrim(COALESCE(p, '')), 1)) || substr(btrim(COALESCE(p, '')), 2)
$$;

-- Acha a lista do usuario pelo nome (exato, plural, ou unica que contenha/esteja contida). NULL se nao achar.
CREATE OR REPLACE FUNCTION f_ls_find(p_user bigint, p_name text) RETURNS bigint
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE n text := f_norm(f_ls_clean(p_name)); v bigint; k int;
BEGIN
  IF n = '' THEN RETURN NULL; END IF;
  SELECT id INTO v FROM lists WHERE user_id = p_user AND name_norm = n ORDER BY id LIMIT 1;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT id INTO v FROM lists WHERE user_id = p_user
    AND regexp_replace(name_norm, 's$', '') = regexp_replace(n, 's$', '') ORDER BY id LIMIT 1;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT count(*), min(id) INTO k, v FROM lists
   WHERE user_id = p_user AND length(n) >= 3
     AND (name_norm LIKE '%' || n || '%' OR (length(name_norm) >= 3 AND n LIKE '%' || name_norm || '%'));
  IF k = 1 THEN RETURN v; END IF;
  RETURN NULL;
END $$;

-- Acha um item da lista. strict=true: so igual (ignora plural); strict=false: aceita unico que contenha.
-- Retorna id, NULL (nao achou) ou 0 (ambiguo).
CREATE OR REPLACE FUNCTION f_ls_item_find(p_list bigint, p_name text, p_strict boolean) RETURNS bigint
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE n text := f_norm(p_name); v bigint; k int;
BEGIN
  IF n = '' THEN RETURN NULL; END IF;
  SELECT id INTO v FROM list_items WHERE list_id = p_list AND name_norm = n ORDER BY done, id LIMIT 1;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT id INTO v FROM list_items WHERE list_id = p_list
    AND regexp_replace(name_norm, 's$', '') = regexp_replace(n, 's$', '') ORDER BY done, id LIMIT 1;
  IF v IS NOT NULL THEN RETURN v; END IF;
  IF p_strict OR length(n) < 3 THEN RETURN NULL; END IF;
  SELECT count(*), min(id) INTO k, v FROM list_items
   WHERE list_id = p_list AND (name_norm LIKE '%' || n || '%' OR (length(name_norm) >= 3 AND n LIKE '%' || name_norm || '%'));
  IF k = 1 THEN RETURN v; END IF;
  IF k > 1 THEN RETURN 0; END IF;
  RETURN NULL;
END $$;

-- Texto da lista com marcadores.
CREATE OR REPLACE FUNCTION f_ls_render(p_list bigint) RETURNS text
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE l lists%ROWTYPE; tot int; pend int; body text; nl text := chr(10);
BEGIN
  SELECT * INTO l FROM lists WHERE id = p_list;
  IF NOT FOUND THEN RETURN ''; END IF;
  SELECT count(*), count(*) FILTER (WHERE NOT done) INTO tot, pend FROM list_items WHERE list_id = p_list;
  IF tot = 0 THEN RETURN 'Lista ' || l.name || ': vazia.'; END IF;
  SELECT string_agg(CASE WHEN done THEN '☑ ' ELSE '☐ ' END || name, nl ORDER BY done, id)
    INTO body FROM (SELECT * FROM list_items WHERE list_id = p_list ORDER BY done, id LIMIT 80) s;
  RETURN 'Lista ' || l.name || ' (' || pend || CASE WHEN pend = 1 THEN ' pendente' ELSE ' pendentes' END || ' de ' || tot || '):' || nl || body
    || CASE WHEN tot > 80 THEN nl || '... e mais ' || (tot - 80) || '.' ELSE '' END;
END $$;

-- Mensagem curta de erro/aviso.
CREATE OR REPLACE FUNCTION f_ls_msg(p text) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT jsonb_build_object('text', p, 'kb', 'none', 'rid', 0)
$$;

-- ---------- f_lists: p = {list_action, list_name, list_items[], text} ----------
CREATE OR REPLACE FUNCTION f_lists(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  nl text := chr(10);
  act text := lower(COALESCE(NULLIF(btrim(p->>'list_action'), ''), 'show'));
  lname text := f_ls_clean(p->>'list_name');
  items text[];
  v_list bigint; v_disp text; n_lists int; names text; it text; iid bigint; k int;
  added text[] := '{}'; dups text[] := '{}'; reop text[] := '{}'; changed text[] := '{}'; same text[] := '{}';
  nf text[] := '{}'; amb text[] := '{}'; parts text[] := '{}';
  pend int; tot int; pid bigint; created boolean := false;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user) THEN RETURN f_ls_msg('Não achei seu cadastro.'); END IF;
  IF act NOT IN ('create','show','add','remove','check','uncheck','clear','delete','lists') THEN act := 'show'; END IF;
  items := COALESCE(ARRAY(
    SELECT x FROM (
      SELECT (array_agg(btrim(left(e, 80)) ORDER BY o))[1] AS x, min(o) AS o
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'list_items') = 'array' THEN p->'list_items' ELSE '[]'::jsonb END) WITH ORDINALITY AS t(e, o)
       WHERE btrim(e) <> '' AND f_norm(e) <> '' GROUP BY f_norm(e)) s ORDER BY o LIMIT 30), '{}');

  SELECT count(*) INTO n_lists FROM lists WHERE user_id = p_user;
  SELECT string_agg(name, ', ' ORDER BY name) INTO names FROM lists WHERE user_id = p_user;

  -- minhas listas
  IF act = 'lists' THEN
    IF n_lists = 0 THEN
      RETURN f_ls_msg('Você ainda não tem listas. Diga, por exemplo: "lista de mercado: arroz, café e detergente".');
    END IF;
    SELECT string_agg('- ' || l.name || ': ' || COALESCE(c.pend, 0) || CASE WHEN COALESCE(c.pend, 0) = 1 THEN ' pendente' ELSE ' pendentes' END
                      || ' de ' || COALESCE(c.tot, 0), nl ORDER BY l.name)
      INTO names
      FROM lists l LEFT JOIN (SELECT list_id, count(*) AS tot, count(*) FILTER (WHERE NOT done) AS pend FROM list_items WHERE user_id = p_user GROUP BY list_id) c ON c.list_id = l.id
     WHERE l.user_id = p_user;
    RETURN f_ls_msg('Suas listas:' || nl || names);
  END IF;

  -- resolver a lista
  IF act = 'create' THEN
    IF lname = '' THEN
      IF cardinality(items) = 0 THEN RETURN f_ls_msg('Qual o nome da lista? Por exemplo: "lista de mercado: arroz, café".'); END IF;
      lname := 'mercado';
    END IF;
    v_list := f_ls_find(p_user, lname);
  ELSE
    IF act = 'add' AND cardinality(items) = 0 THEN RETURN f_ls_msg('Quais itens eu adiciono? Por exemplo: "adiciona sabão em pó na lista".'); END IF;
    IF act IN ('remove','check','uncheck') AND cardinality(items) = 0 THEN
      RETURN f_ls_msg('Qual item? Por exemplo: "marca o arroz" ou "tira o café da lista".');
    END IF;
    IF lname <> '' THEN
      v_list := f_ls_find(p_user, lname);
    ELSIF n_lists = 1 THEN
      SELECT id INTO v_list FROM lists WHERE user_id = p_user;
    ELSIF n_lists > 1 THEN
      RETURN f_ls_msg('De qual lista? Você tem: ' || names || '.');
    ELSIF act = 'add' THEN
      lname := 'mercado';
    ELSE
      RETURN f_ls_msg('Você ainda não tem listas. Diga, por exemplo: "lista de mercado: arroz, café e detergente".');
    END IF;
    IF v_list IS NULL AND act <> 'add' THEN
      RETURN f_ls_msg('Não achei essa lista.' || CASE WHEN n_lists > 0 THEN ' Suas listas: ' || names || '.' ELSE '' END);
    END IF;
  END IF;

  IF v_list IS NULL THEN
    IF f_norm(lname) = '' THEN RETURN f_ls_msg('Não entendi o nome da lista. Pode repetir?'); END IF;
    INSERT INTO lists (user_id, name, name_norm) VALUES (p_user, f_ls_disp(left(lname, 60)), f_norm(lname))
      ON CONFLICT (user_id, name_norm) DO NOTHING;
    SELECT id INTO v_list FROM lists WHERE user_id = p_user AND name_norm = f_norm(lname);
    created := true;
  END IF;
  SELECT name INTO v_disp FROM lists WHERE id = v_list AND user_id = p_user;
  IF v_disp IS NULL THEN RETURN f_ls_msg('Não achei essa lista.'); END IF;

  IF act IN ('create', 'add') THEN
    SELECT count(*) INTO tot FROM list_items WHERE list_id = v_list;
    IF tot + cardinality(items) > 300 THEN RETURN f_ls_msg('Essa lista já está muito grande (limite de 300 itens).'); END IF;
    FOREACH it IN ARRAY items LOOP
      iid := f_ls_item_find(v_list, it, true);
      IF iid IS NOT NULL AND iid > 0 THEN
        IF (SELECT done FROM list_items WHERE id = iid) THEN
          UPDATE list_items SET done = false, done_at = NULL WHERE id = iid;
          reop := reop || it;
        ELSE
          dups := dups || it;
        END IF;
      ELSE
        INSERT INTO list_items (list_id, user_id, name, name_norm) VALUES (v_list, p_user, it, f_norm(it));
        added := added || it;
      END IF;
    END LOOP;
    SELECT count(*) FILTER (WHERE NOT done), count(*) INTO pend, tot FROM list_items WHERE list_id = v_list;
    IF cardinality(added) > 0 THEN parts := parts || ('Adicionei na lista ' || v_disp || ': ' || array_to_string(added, ', ') || '.'); END IF;
    IF cardinality(reop) > 0 THEN parts := parts || ('Voltou para pendente: ' || array_to_string(reop, ', ') || '.'); END IF;
    IF cardinality(dups) > 0 THEN parts := parts || ('Já estava na lista: ' || array_to_string(dups, ', ') || '.'); END IF;
    IF cardinality(added) = 0 AND cardinality(reop) = 0 AND cardinality(dups) = 0 THEN
      parts := parts || ('Criei a lista ' || v_disp || ' (vazia). Diga "adiciona ... na lista ' || lower(v_disp) || '".');
    ELSIF created AND act = 'add' THEN
      parts := parts || ('(Criei a lista ' || v_disp || '.)');
    END IF;
    IF tot > 0 THEN parts := parts || ('Pendentes: ' || pend || ' de ' || tot || '.'); END IF;
    RETURN f_ls_msg(array_to_string(parts, ' '));
  END IF;

  IF act = 'remove' THEN
    FOREACH it IN ARRAY items LOOP
      iid := f_ls_item_find(v_list, it, false);
      IF iid IS NULL THEN nf := nf || it;
      ELSIF iid = 0 THEN amb := amb || it;
      ELSE
        changed := changed || (SELECT name FROM list_items WHERE id = iid);
        DELETE FROM list_items WHERE id = iid AND user_id = p_user AND list_id = v_list;
      END IF;
    END LOOP;
    SELECT count(*) FILTER (WHERE NOT done), count(*) INTO pend, tot FROM list_items WHERE list_id = v_list;
    IF cardinality(changed) > 0 THEN parts := parts || ('Tirei da lista ' || v_disp || ': ' || array_to_string(changed, ', ') || '.'); END IF;
    IF cardinality(nf) > 0 THEN parts := parts || ('Não achei na lista: ' || array_to_string(nf, ', ') || '.'); END IF;
    IF cardinality(amb) > 0 THEN parts := parts || ('Tem mais de um item parecido com: ' || array_to_string(amb, ', ') || '. Diga o nome completo.'); END IF;
    parts := parts || ('Restam ' || tot || CASE WHEN tot = 1 THEN ' item.' ELSE ' itens.' END);
    RETURN f_ls_msg(array_to_string(parts, ' '));
  END IF;

  IF act IN ('check', 'uncheck') THEN
    FOREACH it IN ARRAY items LOOP
      iid := f_ls_item_find(v_list, it, false);
      IF iid IS NULL THEN nf := nf || it;
      ELSIF iid = 0 THEN amb := amb || it;
      ELSE
        IF (SELECT done FROM list_items WHERE id = iid) = (act = 'check') THEN
          same := same || (SELECT name FROM list_items WHERE id = iid);
        ELSE
          UPDATE list_items SET done = (act = 'check'), done_at = CASE WHEN act = 'check' THEN now() ELSE NULL END
           WHERE id = iid AND user_id = p_user AND list_id = v_list;
          changed := changed || (SELECT name FROM list_items WHERE id = iid);
        END IF;
      END IF;
    END LOOP;
    SELECT count(*) FILTER (WHERE NOT done), count(*) INTO pend, tot FROM list_items WHERE list_id = v_list;
    IF cardinality(changed) > 0 THEN
      parts := parts || ((CASE WHEN act = 'check' THEN 'Marquei como comprado: ' ELSE 'Voltou para pendente: ' END) || array_to_string(changed, ', ') || '.');
    END IF;
    IF cardinality(same) > 0 THEN
      parts := parts || ('Já estava ' || CASE WHEN act = 'check' THEN 'marcado: ' ELSE 'pendente: ' END || array_to_string(same, ', ') || '.');
    END IF;
    IF cardinality(nf) > 0 THEN parts := parts || ('Não achei na lista ' || v_disp || ': ' || array_to_string(nf, ', ') || '.'); END IF;
    IF cardinality(amb) > 0 THEN parts := parts || ('Tem mais de um item parecido com: ' || array_to_string(amb, ', ') || '. Diga o nome completo.'); END IF;
    IF tot > 0 AND pend = 0 THEN parts := parts || 'Tudo comprado! Diga "limpa a lista" se quiser esvaziá-la.'::text;
    ELSE parts := parts || ('Pendentes: ' || pend || ' de ' || tot || '.'); END IF;
    RETURN f_ls_msg(array_to_string(parts, ' '));
  END IF;

  IF act = 'show' THEN
    RETURN f_ls_msg(f_ls_render(v_list));
  END IF;

  -- destrutivas: pedem confirmacao por botao
  SELECT count(*) INTO tot FROM list_items WHERE list_id = v_list;
  IF act = 'clear' AND tot = 0 THEN RETURN f_ls_msg('A lista ' || v_disp || ' já está vazia.'); END IF;
  UPDATE list_pending SET state = 'cancelled' WHERE user_id = p_user AND state = 'open';
  INSERT INTO list_pending (user_id, kind, target_id, target_name)
    VALUES (p_user, CASE WHEN act = 'clear' THEN 'clear_list' ELSE 'delete_list' END, v_list, v_disp)
    RETURNING id INTO pid;
  IF act = 'clear' THEN
    RETURN jsonb_build_object('text', 'Esvaziar a lista ' || v_disp || '? Os ' || tot || ' itens serão apagados (a lista continua existindo).', 'kb', 'ls_confirm', 'rid', pid);
  END IF;
  RETURN jsonb_build_object('text', 'Apagar a lista ' || v_disp || ' com ' || tot || CASE WHEN tot = 1 THEN ' item?' ELSE ' itens?' END, 'kb', 'ls_confirm', 'rid', pid);
EXCEPTION WHEN OTHERS THEN
  RETURN f_ls_msg('Não consegui mexer na lista agora. Tente de novo.');
END $$;

-- ---------- notas ----------
-- Busca por palavras (sem acento; todas as palavras, senao qualquer uma), mais recentes primeiro.
-- Sem palavras uteis na consulta: devolve as ultimas notas.
CREATE OR REPLACE FUNCTION f_nt_search(p_user bigint, p_q text, p_limit int)
RETURNS TABLE (id bigint, body text, created_at timestamptz, total bigint)
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE
  stop text[] := ARRAY['de','da','do','das','dos','um','uma','uns','umas','que','qual','quais','sobre','eu','tinha','tenho','anotado','anotei','anota',
    'nota','notas','minha','minhas','meu','meus','para','pra','com','em','no','na','nos','nas','ele','ela','isso','esse','essa','aquilo','foi','era','ver','mostra','mostrar',
    'procura','busca','acha','achar','lembra','sobre','tem','algo','alguma','algum','por','mais','como','ultima','ultimas','ultimo','ultimos','apaga','apagar','exclui','remove','tira'];
  toks text[]; k bigint; minscore int;
BEGIN
  toks := COALESCE(ARRAY(
    SELECT DISTINCT CASE WHEN length(t) >= 6 THEN left(t, length(t) - 2) WHEN length(t) >= 4 THEN rtrim(t, 's') ELSE t END
      FROM unnest(string_to_array(f_norm(p_q), ' ')) AS t
     WHERE length(t) >= 3 AND NOT (t = ANY (stop))), '{}');
  IF cardinality(toks) = 0 THEN
    RETURN QUERY SELECT n.id, n.body, n.created_at, count(*) OVER ()
      FROM notes n WHERE n.user_id = p_user ORDER BY n.created_at DESC, n.id DESC LIMIT p_limit;
    RETURN;
  END IF;
  SELECT count(*) INTO k FROM notes n
   WHERE n.user_id = p_user AND (SELECT count(*) FROM unnest(toks) t WHERE n.body_norm LIKE '%' || t || '%') = cardinality(toks);
  minscore := CASE WHEN k > 0 THEN cardinality(toks) ELSE 1 END;
  RETURN QUERY
    SELECT s.id, s.body, s.created_at, count(*) OVER ()
      FROM (SELECT n.id, n.body, n.created_at,
                   (SELECT count(*) FROM unnest(toks) t WHERE n.body_norm LIKE '%' || t || '%') AS score
              FROM notes n WHERE n.user_id = p_user) s
     WHERE s.score >= minscore
     ORDER BY s.score DESC, s.created_at DESC, s.id DESC LIMIT p_limit;
END $$;

CREATE OR REPLACE FUNCTION f_nt_snip(p text, p_len int) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT CASE WHEN length(regexp_replace(COALESCE(p, ''), '[[:space:]]+', ' ', 'g')) > p_len
              THEN left(regexp_replace(COALESCE(p, ''), '[[:space:]]+', ' ', 'g'), p_len - 3) || '...'
              ELSE regexp_replace(COALESCE(p, ''), '[[:space:]]+', ' ', 'g') END
$$;

-- ---------- f_notes: p = {note_action, note_text, note_query, text} ----------
CREATE OR REPLACE FUNCTION f_notes(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  nl text := chr(10);
  act text := lower(COALESCE(NULLIF(btrim(p->>'note_action'), ''), 'list'));
  v_body text; q text; tzn text; r record; out_t text := ''; k int := 0; tot bigint := 0; pid bigint; nid bigint; nbody text;
BEGIN
  SELECT COALESCE(NULLIF(timezone, ''), 'America/Sao_Paulo') INTO tzn FROM users WHERE id = p_user;
  IF tzn IS NULL THEN RETURN f_ls_msg('Não achei seu cadastro.'); END IF;
  IF act NOT IN ('save','search','list','delete') THEN act := 'list'; END IF;
  q := btrim(COALESCE(p->>'note_query', ''));

  IF act = 'save' THEN
    v_body := btrim(COALESCE(NULLIF(btrim(p->>'note_text'), ''), p->>'text', ''));
    IF f_norm(v_body) = '' THEN RETURN f_ls_msg('O que eu anoto? Por exemplo: "anota a ideia da assinatura anual".'); END IF;
    IF length(v_body) > 4000 THEN v_body := left(v_body, 4000); END IF;
    IF EXISTS (SELECT 1 FROM notes WHERE user_id = p_user AND body_norm = f_norm(v_body) AND created_at > now() - interval '2 minutes') THEN
      RETURN f_ls_msg('Essa nota eu acabei de guardar.');
    END IF;
    INSERT INTO notes (user_id, body, body_norm) VALUES (p_user, v_body, f_norm(v_body)) RETURNING id INTO nid;
    RETURN f_ls_msg('Anotado: "' || f_nt_snip(v_body, 120) || '"');
  END IF;

  IF act = 'search' OR act = 'list' THEN
    IF act = 'list' THEN q := ''; END IF;
    FOR r IN SELECT * FROM f_nt_search(p_user, q, CASE WHEN act = 'list' THEN 8 ELSE 5 END) LOOP
      k := k + 1; tot := r.total;
      out_t := out_t || k || ') ' || to_char(r.created_at AT TIME ZONE tzn, 'DD/MM/YYYY') || ': ' || f_nt_snip(r.body, CASE WHEN act = 'list' THEN 110 ELSE 160 END) || nl;
    END LOOP;
    IF k = 0 THEN
      RETURN f_ls_msg(CASE WHEN act = 'list' OR f_norm(q) = '' THEN 'Você ainda não tem notas. Diga, por exemplo: "anota a ideia da assinatura anual".'
                           ELSE 'Não achei nenhuma nota sobre isso.' END);
    END IF;
    RETURN f_ls_msg((CASE WHEN act = 'list' THEN 'Suas últimas notas:' ELSE 'Achei ' || CASE WHEN tot = 1 THEN 'esta nota:' ELSE tot || ' notas' || CASE WHEN tot > 5 THEN ' (mostro as 5 mais recentes):' ELSE ':' END END END)
                    || nl || btrim(out_t, nl));
  END IF;

  -- apagar: acha por palavras (sem palavras = a ultima nota) e pede confirmacao
  FOR r IN SELECT * FROM f_nt_search(p_user, q, 5) LOOP
    k := k + 1; tot := r.total;
    IF k = 1 THEN nid := r.id; nbody := r.body; END IF;
    out_t := out_t || k || ') ' || to_char(r.created_at AT TIME ZONE tzn, 'DD/MM/YYYY') || ': ' || f_nt_snip(r.body, 110) || nl;
  END LOOP;
  IF k = 0 THEN RETURN f_ls_msg(CASE WHEN f_norm(q) = '' THEN 'Você não tem notas para apagar.' ELSE 'Não achei nenhuma nota sobre isso.' END); END IF;
  IF f_norm(q) <> '' AND tot > 1 THEN
    RETURN f_ls_msg('Achei ' || tot || ' notas parecidas:' || nl || btrim(out_t, nl) || nl || 'Diga mais palavras da nota que você quer apagar.');
  END IF;
  UPDATE list_pending SET state = 'cancelled' WHERE user_id = p_user AND state = 'open';
  INSERT INTO list_pending (user_id, kind, target_id, target_name) VALUES (p_user, 'delete_note', nid, f_nt_snip(nbody, 60)) RETURNING id INTO pid;
  RETURN jsonb_build_object('text', 'Apagar esta nota?' || nl || '"' || f_nt_snip(nbody, 200) || '"', 'kb', 'ls_confirm', 'rid', pid);
EXCEPTION WHEN OTHERS THEN
  RETURN f_ls_msg('Não consegui mexer nas notas agora. Tente de novo.');
END $$;

-- ---------- f_lists_cb: botoes lsok / lsno ----------
CREATE OR REPLACE FUNCTION f_lists_cb(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint; pd list_pending%ROWTYPE; n int;
BEGIN
  BEGIN v_id := NULLIF(split_part(p_data, ':', 2), '')::bigint; EXCEPTION WHEN OTHERS THEN v_id := NULL; END;
  IF a NOT IN ('lsok', 'lsno') OR v_id IS NULL THEN RETURN f_ls_msg('Não entendi esse botão.'); END IF;
  SELECT * INTO pd FROM list_pending WHERE id = v_id AND user_id = p_user FOR UPDATE;
  IF NOT FOUND THEN RETURN f_ls_msg('Não encontrei essa confirmação.'); END IF;
  IF pd.state <> 'open' THEN RETURN f_ls_msg('Essa confirmação já foi respondida.'); END IF;
  IF pd.created_at < now() - interval '1 day' THEN
    UPDATE list_pending SET state = 'cancelled' WHERE id = v_id;
    RETURN f_ls_msg('Essa confirmação expirou. Peça de novo.');
  END IF;
  IF a = 'lsno' THEN
    UPDATE list_pending SET state = 'cancelled' WHERE id = v_id;
    RETURN f_ls_msg('Ok, não apaguei nada.');
  END IF;
  IF pd.kind = 'delete_list' THEN
    DELETE FROM lists WHERE id = pd.target_id AND user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE list_pending SET state = 'done' WHERE id = v_id;
    RETURN f_ls_msg(CASE WHEN n > 0 THEN 'Pronto, apaguei a lista ' || pd.target_name || '.' ELSE 'A lista ' || pd.target_name || ' já não existia.' END);
  ELSIF pd.kind = 'clear_list' THEN
    DELETE FROM list_items WHERE list_id = pd.target_id AND user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE list_pending SET state = 'done' WHERE id = v_id;
    RETURN f_ls_msg('Pronto, esvaziei a lista ' || pd.target_name || ' (' || n || CASE WHEN n = 1 THEN ' item).' ELSE ' itens).' END);
  ELSE
    DELETE FROM notes WHERE id = pd.target_id AND user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE list_pending SET state = 'done' WHERE id = v_id;
    RETURN f_ls_msg(CASE WHEN n > 0 THEN 'Pronto, apaguei a nota.' ELSE 'Essa nota já não existia.' END);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RETURN f_ls_msg('Não consegui concluir agora. Tente de novo.');
END $$;

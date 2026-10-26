-- 015_documentos.sql: modulo Documentos (fase 4, D)
-- Guarda SO o file_id do Telegram + metadados (nome, descricao, pasta, tipo, tamanho). Nunca o conteudo.
-- Idempotente: CREATE ... IF NOT EXISTS / CREATE OR REPLACE.
-- Entradas do n8n: f_docs_inbox_note (arquivo recebido), f_docs_file (arquivo de qualquer tipo, sem IA),
-- f_docs (intent document_manage), f_docs_cb (botoes dc*).

SET search_path TO agente, public;

-- ---------- tabelas ----------
CREATE TABLE IF NOT EXISTS agente.doc_folders (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES agente.users(id) ON DELETE CASCADE,
  name       text   NOT NULL,
  name_norm  text   NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, name_norm)
);

CREATE TABLE IF NOT EXISTS agente.documents (
  id          bigserial PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES agente.users(id) ON DELETE CASCADE,
  folder_id   bigint REFERENCES agente.doc_folders(id) ON DELETE SET NULL,
  title       text   NOT NULL,
  description text,
  file_id     text   NOT NULL,
  tg_type     text   NOT NULL DEFAULT 'document' CHECK (tg_type IN ('photo','document','video')),
  mime        text,
  file_name   text,
  file_size   bigint,
  expires_on  date,
  reminder_id bigint REFERENCES agente.reminders(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS documents_user ON agente.documents (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS documents_folder ON agente.documents (folder_id);

-- arquivo recebido recentemente (qualquer arquivo que chega); nao e consumido ate o usuario pedir para guardar
CREATE TABLE IF NOT EXISTS agente.doc_inbox (
  id          bigserial PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES agente.users(id) ON DELETE CASCADE,
  file_id     text   NOT NULL,
  tg_type     text   NOT NULL DEFAULT 'document' CHECK (tg_type IN ('photo','document','video')),
  mime        text,
  file_name   text,
  file_size   bigint,
  caption     text,
  consumed    boolean NOT NULL DEFAULT false,
  received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS doc_inbox_user ON agente.doc_inbox (user_id, received_at DESC);

-- ---------- helpers ----------
-- palavras de busca (sem acento, sem palavras vazias, plural simples)
CREATE OR REPLACE FUNCTION agente.f_doc_tokens(p text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $f$
  SELECT coalesce(array_agg(DISTINCT z.t), ARRAY[]::text[]) FROM (
    SELECT CASE WHEN length(x) > 3 AND right(x, 1) = 's' THEN left(x, length(x) - 1) ELSE x END AS t
    FROM unnest(string_to_array(f_norm(p), ' ')) x
    WHERE length(x) >= 2 AND x NOT IN (
      'de','do','da','dos','das','no','na','nos','nas','em','um','uma','uns','umas','ao','aos','as','os','pra','para','por','com','sem',
      'que','qual','quais','meu','minha','meus','minhas','esse','essa','esses','essas','este','esta','isso','aquele','aquela',
      'me','te','se','vc','voce','manda','mandar','envia','enviar','mostra','mostrar','acha','achar','achei','busca','buscar','procura','procurar',
      'tudo','todo','toda','todos','todas','arquivo','arquivos','documento','documentos','doc','docs','pasta','pastas',
      'foto','fotos','imagem','imagens','print','prints','screenshot','pdf','sobre','link','aqui','ai','ver','tem','ter','onde','cade','quero')
  ) z WHERE z.t <> ''
$f$;

-- busca: devolve documentos do usuario; exact_hit = casou todas as palavras
CREATE OR REPLACE FUNCTION agente.f_doc_search(p_user bigint, p_q text, p_folder bigint DEFAULT NULL, p_limit integer DEFAULT 10)
RETURNS TABLE(doc_id bigint, score integer, exact_hit boolean)
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $f$
DECLARE v_tok text[] := f_doc_tokens(p_q); n integer; w_photo boolean; w_pdf boolean; nq text := f_norm(p_q);
BEGIN
  n := cardinality(v_tok);
  w_photo := nq ~ '(^| )(foto|fotos|imagem|imagens|print|prints|screenshot)( |$)';
  w_pdf   := nq ~ '(^| )pdf( |$)';
  RETURN QUERY
  SELECT s.id, s.m, (s.m = n) FROM (
    SELECT d.id, d.created_at,
           (SELECT count(*) FROM unnest(v_tok) t WHERE z.h LIKE '%' || t || '%')::integer AS m,
           ((w_photo AND (d.tg_type = 'photo' OR coalesce(d.mime, '') LIKE 'image/%'))
             OR (w_pdf AND (coalesce(d.mime, '') ILIKE '%pdf' OR coalesce(d.file_name, '') ILIKE '%.pdf'))) AS tm
    FROM documents d LEFT JOIN doc_folders f ON f.id = d.folder_id
    CROSS JOIN LATERAL (SELECT f_norm(d.title || ' ' || coalesce(d.description, '') || ' ' || coalesce(d.file_name, '') || ' ' || coalesce(f.name, '')) AS h) z
    WHERE d.user_id = p_user AND (p_folder IS NULL OR d.folder_id = p_folder)
  ) s
  WHERE (n = 0 AND (NOT (w_photo OR w_pdf) OR s.tm)) OR (n > 0 AND s.m > 0)
  ORDER BY (s.m = n) DESC, s.tm DESC, s.m DESC, s.created_at DESC
  LIMIT greatest(p_limit, 1);
END $f$;

-- pasta pelo nome (igual, ou parecida). NULL se nao achar
CREATE OR REPLACE FUNCTION agente.f_doc_folder_find(p_user bigint, p_name text)
RETURNS bigint LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $f$
DECLARE v_raw text := f_norm(p_name); v_clean text; v_id bigint;
BEGIN
  IF v_raw = '' THEN RETURN NULL; END IF;
  v_clean := coalesce(nullif(array_to_string(f_doc_tokens(p_name), ' '), ''), v_raw);
  SELECT id INTO v_id FROM doc_folders
   WHERE user_id = p_user AND (name_norm = v_raw OR name_norm LIKE '%' || v_clean || '%' OR v_raw LIKE '%' || name_norm || '%')
   ORDER BY (name_norm = v_raw) DESC, length(name_norm) ASC LIMIT 1;
  RETURN v_id;
END $f$;

-- cria a pasta se nao existir; devolve id. p_created diz se criou
CREATE OR REPLACE FUNCTION agente.f_doc_folder_ensure(p_user bigint, p_name text, OUT o_id bigint, OUT o_created boolean)
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE v_name text := btrim(regexp_replace(coalesce(p_name, ''), '[[:space:]]+', ' ', 'g')); v_norm text;
BEGIN
  v_name := left(v_name, 60);
  v_name := upper(left(v_name, 1)) || substr(v_name, 2);
  v_norm := f_norm(v_name);
  o_created := false;
  IF v_norm = '' THEN o_id := NULL; RETURN; END IF;
  SELECT id INTO o_id FROM doc_folders WHERE user_id = p_user AND name_norm = v_norm;
  IF o_id IS NULL THEN o_id := f_doc_folder_find(p_user, v_name); END IF;
  IF o_id IS NULL THEN
    INSERT INTO doc_folders(user_id, name, name_norm) VALUES (p_user, v_name, v_norm)
    ON CONFLICT (user_id, name_norm) DO NOTHING RETURNING id INTO o_id;
    IF o_id IS NULL THEN SELECT id INTO o_id FROM doc_folders WHERE user_id = p_user AND name_norm = v_norm; ELSE o_created := true; END IF;
  END IF;
END $f$;

-- documento(s) pelo nome. Vazio = o ultimo guardado (ate 2 dias). Exato primeiro; se so houver um parecido, usa ele.
CREATE OR REPLACE FUNCTION agente.f_doc_resolve(p_user bigint, p_q text, p_folder bigint DEFAULT NULL, p_last boolean DEFAULT true)
RETURNS bigint[] LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $f$
DECLARE v_ids bigint[];
BEGIN
  IF cardinality(f_doc_tokens(p_q)) = 0 THEN
    IF NOT p_last THEN RETURN ARRAY[]::bigint[]; END IF;
    RETURN ARRAY(SELECT id FROM documents WHERE user_id = p_user AND created_at > now() - interval '2 days' ORDER BY created_at DESC, id DESC LIMIT 1);
  END IF;
  v_ids := ARRAY(SELECT doc_id FROM f_doc_search(p_user, p_q, p_folder, 6) WHERE exact_hit);
  IF cardinality(v_ids) = 0 THEN
    v_ids := ARRAY(SELECT doc_id FROM f_doc_search(p_user, p_q, p_folder, 2));
    IF cardinality(v_ids) <> 1 THEN v_ids := ARRAY[]::bigint[]; END IF;
  END IF;
  RETURN v_ids;
END $f$;

-- cancela o aviso de vencimento de um documento
CREATE OR REPLACE FUNCTION agente.f_doc_unremind(p_doc bigint) RETURNS void
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE v_rid bigint;
BEGIN
  SELECT reminder_id INTO v_rid FROM documents WHERE id = p_doc;
  IF v_rid IS NOT NULL THEN
    UPDATE notifications SET state = 'cancelled' WHERE reminder_id = v_rid AND state = 'pending';
    UPDATE reminders SET status = 'cancelled' WHERE id = v_rid AND status IN ('pending','awaiting_time');
  END IF;
  UPDATE documents SET reminder_id = NULL WHERE id = p_doc;
END $f$;

-- grava a validade e agenda o aviso (reminders + notifications tipo 'reminder': o Disparador entrega). Devolve o texto.
CREATE OR REPLACE FUNCTION agente.f_doc_expiry_apply(p_user bigint, p_doc bigint, p_exp date, p_days integer DEFAULT 7)
RETURNS text LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE d documents%ROWTYPE; tz text; v_today date; v_due timestamptz; v_adj boolean := false; v_days integer := least(greatest(coalesce(p_days, 7), 0), 365); v_rid bigint; v_ttl text;
BEGIN
  SELECT * INTO d FROM documents WHERE id = p_doc AND user_id = p_user;
  IF NOT FOUND THEN RETURN 'Não achei esse documento.'; END IF;
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  v_today := (now() AT TIME ZONE tz)::date;
  PERFORM f_doc_unremind(p_doc);
  UPDATE documents SET expires_on = p_exp WHERE id = p_doc;
  IF p_exp < v_today THEN
    RETURN 'Guardei a validade de "' || d.title || '" (' || to_char(p_exp, 'DD/MM/YYYY') || '), mas essa data já passou, então não marquei aviso.';
  END IF;
  v_due := ((p_exp - v_days)::timestamp + time '09:00') AT TIME ZONE tz;
  IF v_due <= now() THEN
    v_adj := true;
    IF p_exp >= v_today + 1 THEN v_due := ((v_today + 1)::timestamp + time '09:00') AT TIME ZONE tz;
    ELSE v_due := now() + interval '2 minutes'; END IF;
  END IF;
  v_ttl := 'Vencimento: ' || d.title || ' (vence em ' || to_char(p_exp, 'DD/MM/YYYY') || ')';
  INSERT INTO reminders(user_id, kind, title, due_at, status, source) VALUES (p_user, 'reminder', v_ttl, v_due, 'pending', 'text') RETURNING id INTO v_rid;
  INSERT INTO notifications(user_id, reminder_id, type, fire_at) VALUES (p_user, v_rid, 'reminder', v_due);
  UPDATE documents SET reminder_id = v_rid WHERE id = p_doc;
  RETURN '"' || d.title || '" vence em ' || to_char(p_exp, 'DD/MM/YYYY') || '. Vou te avisar em ' || to_char(v_due AT TIME ZONE tz, 'DD/MM/YYYY "às" HH24:MI')
         || CASE WHEN NOT v_adj THEN ' (' || v_days || CASE WHEN v_days = 1 THEN ' dia' ELSE ' dias' END || ' antes).' ELSE '.' END;
END $f$;

-- limpa o texto de legenda (o envio usa parse HTML por padrao)
CREATE OR REPLACE FUNCTION agente.f_doc_caption(p_title text, p_folder text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $f$
  SELECT left(regexp_replace(coalesce(p_title, '') || CASE WHEN coalesce(p_folder, '') <> '' THEN ' - ' || p_folder ELSE '' END, '[<>&]', '', 'g'), 200)
$f$;

-- ---------- arquivo recebido (qualquer arquivo; sem IA) ----------
CREATE OR REPLACE FUNCTION agente.f_docs_inbox_note(p_user bigint, p_req jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE v_type text := coalesce(nullif(p_req->>'tg_type', ''), 'document');
BEGIN
  IF p_user IS NULL OR p_user <= 0 OR coalesce(p_req->>'file_id', '') = '' THEN RETURN jsonb_build_object('ok', false); END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user) THEN RETURN jsonb_build_object('ok', false); END IF;
  IF v_type NOT IN ('photo','document','video') THEN v_type := 'document'; END IF;
  DELETE FROM doc_inbox WHERE received_at < now() - interval '2 days';
  INSERT INTO doc_inbox(user_id, file_id, tg_type, mime, file_name, file_size, caption)
  VALUES (p_user, p_req->>'file_id', v_type, nullif(p_req->>'mime', ''), nullif(p_req->>'file_name', ''),
          CASE WHEN coalesce(p_req->>'file_size', '') ~ '^[0-9]{1,15}$' THEN (p_req->>'file_size')::bigint END, nullif(left(p_req->>'caption', 500), ''));
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_docs_inbox_note: %', SQLERRM;
  RETURN jsonb_build_object('ok', false);
END $f$;

-- ---------- guardar o(s) arquivo(s) recebido(s) ----------
CREATE OR REPLACE FUNCTION agente.f_docs_save(p_user bigint, p_req jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE
  v_fid text := coalesce(p_req->>'file_id', ''); a doc_inbox%ROWTYPE; r doc_inbox%ROWTYPE;
  v_title text := btrim(coalesce(p_req->>'title', '')); v_desc text := btrim(coalesce(p_req->>'query', ''));
  v_folder text := btrim(coalesce(p_req->>'folder', '')); v_fid_folder bigint; v_created boolean := false; v_fname text;
  v_exp date := f_safe_date(p_req->>'expires_on'); v_days integer := nullif(p_req->>'alert_days', '')::integer;
  v_ids bigint[]; v_n integer := 0; v_dup integer := 0; v_i integer := 0; v_total integer; v_docid bigint; v_ttl text; v_first_doc bigint;
  v_tz text; v_txt text; v_base text;
BEGIN
  SELECT * INTO a FROM doc_inbox WHERE user_id = p_user AND NOT consumed AND received_at > now() - interval '15 minutes'
     AND (v_fid = '' OR file_id = v_fid) ORDER BY received_at DESC, id DESC LIMIT 1;
  IF NOT FOUND AND v_fid <> '' THEN
    SELECT * INTO a FROM doc_inbox WHERE user_id = p_user AND NOT consumed AND received_at > now() - interval '15 minutes' ORDER BY received_at DESC, id DESC LIMIT 1;
  END IF;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('text', 'Não achei nenhum arquivo seu dos últimos minutos para guardar. Me mande o arquivo (foto, PDF ou outro) e diga "guarda", ou mande já com a legenda "guarda".', 'kb', 'none', 'rid', 0);
  END IF;
  -- varios arquivos mandados juntos (album) entram no mesmo "guarda"; 'single' = so o arquivo ancora
  v_ids := ARRAY(SELECT id FROM doc_inbox WHERE user_id = p_user AND NOT consumed AND received_at > now() - interval '15 minutes'
                  AND (id = a.id OR (coalesce(p_req->>'single', '') <> 'true' AND abs(extract(epoch FROM received_at - a.received_at)) <= 30))
                  ORDER BY received_at, id LIMIT 10);
  v_total := cardinality(v_ids);
  IF v_folder <> '' THEN
    SELECT o_id, o_created INTO v_fid_folder, v_created FROM f_doc_folder_ensure(p_user, v_folder);
  END IF;
  FOR r IN SELECT * FROM doc_inbox WHERE id = ANY (v_ids) ORDER BY received_at, id LOOP
    v_i := v_i + 1;
    UPDATE doc_inbox SET consumed = true WHERE id = r.id;
    IF EXISTS (SELECT 1 FROM documents WHERE user_id = p_user AND file_id = r.file_id) THEN v_dup := v_dup + 1; CONTINUE; END IF;
    v_fname := nullif(btrim(replace(replace(regexp_replace(coalesce(r.file_name, ''), '\.[A-Za-z0-9]{1,6}$', ''), '_', ' '), '-', ' ')), '');
    v_base := coalesce(nullif(v_title, ''), v_fname, nullif(left(coalesce(nullif(v_desc, ''), r.caption, ''), 50), ''), 'Arquivo de ' || to_char(now() AT TIME ZONE coalesce((SELECT timezone FROM users WHERE id = p_user), 'America/Sao_Paulo'), 'DD/MM'));
    v_ttl := CASE WHEN v_total > 1 AND v_title <> '' THEN left(v_base, 70) || ' ' || v_i ELSE left(v_base, 80) END;
    INSERT INTO documents(user_id, folder_id, title, description, file_id, tg_type, mime, file_name, file_size)
    VALUES (p_user, v_fid_folder, v_ttl, left(coalesce(nullif(v_desc, ''), r.caption), 500), r.file_id, r.tg_type, r.mime, r.file_name, r.file_size)
    RETURNING id INTO v_docid;
    v_n := v_n + 1;
    IF v_first_doc IS NULL THEN v_first_doc := v_docid; END IF;
  END LOOP;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('text', CASE WHEN v_dup > 1 THEN 'Esses arquivos já estavam guardados.' ELSE 'Esse arquivo já estava guardado.' END, 'kb', 'none', 'rid', 0);
  END IF;
  v_txt := CASE WHEN v_n = 1 THEN 'Guardei "' || v_ttl || '"' ELSE 'Guardei ' || v_n || ' arquivos' END;
  IF v_fid_folder IS NOT NULL THEN
    v_txt := v_txt || ' na pasta ' || (SELECT name FROM doc_folders WHERE id = v_fid_folder) || CASE WHEN v_created THEN ' (criei a pasta)' ELSE '' END;
  END IF;
  v_txt := v_txt || '.';
  IF v_dup > 0 THEN v_txt := v_txt || ' ' || v_dup || CASE WHEN v_dup = 1 THEN ' já estava guardado.' ELSE ' já estavam guardados.' END; END IF;
  IF v_exp IS NOT NULL AND v_first_doc IS NOT NULL THEN
    v_txt := v_txt || ' ' || f_doc_expiry_apply(p_user, v_first_doc, v_exp, coalesce(v_days, 7));
  END IF;
  RETURN jsonb_build_object('text', v_txt, 'kb', 'none', 'rid', 0);
END $f$;

-- ---------- arquivo de qualquer tipo, sem IA (zip, docx, video, PDF/imagem grande) ----------
CREATE OR REPLACE FUNCTION agente.f_docs_file(p_user bigint, p_req jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE v_cap text := coalesce(p_req->>'caption', ''); v_size bigint; v_fname text := coalesce(p_req->>'file_name', ''); v_folder text; m text[]; v_res jsonb; v_label text; v_mb text;
BEGIN
  IF p_user IS NULL OR p_user <= 0 THEN RETURN jsonb_build_object('text', 'Não consegui identificar você.', 'kb', 'none', 'rid', 0); END IF;
  v_size := CASE WHEN coalesce(p_req->>'file_size', '') ~ '^[0-9]{1,15}$' THEN (p_req->>'file_size')::bigint END;
  IF v_size IS NOT NULL AND v_size > 52428800 THEN
    RETURN jsonb_build_object('text', 'Esse arquivo passa de 50 MB, o limite que o Telegram permite para eu guardar e reenviar. Mande um menor.', 'kb', 'none', 'rid', 0);
  END IF;
  PERFORM f_docs_inbox_note(p_user, p_req);
  IF f_norm(v_cap) ~ '(^| )(guarda|guardar|guarde|salva|salvar|salve|arquiva|arquivar|arquive)( |$)' THEN
    m := regexp_match(v_cap, 'pasta[[:space:]]+(?:d[aeo]s?[[:space:]]+)?([^,.;!?]+)', 'i');
    v_res := f_docs_save(p_user, jsonb_build_object('file_id', p_req->>'file_id', 'folder', btrim(coalesce(m[1], '')), 'query', v_cap, 'single', 'true'));
    RETURN v_res;
  END IF;
  v_label := CASE WHEN v_fname <> '' THEN '"' || v_fname || '"' ELSE 'o arquivo' END;
  v_mb := CASE WHEN v_size IS NOT NULL THEN ' (' || round(v_size / 1048576.0, 1)::text || ' MB)' ELSE '' END;
  RETURN jsonb_build_object('text', 'Recebi ' || v_label || v_mb || '. Quer que eu guarde? Diga "guarda" (pode dizer a pasta, por exemplo: "guarda na pasta Casa"). Depois é só pedir: "acha o ' || coalesce(nullif(regexp_replace(v_fname, '\.[A-Za-z0-9]{1,6}$', ''), ''), 'arquivo') || '".', 'kb', 'none', 'rid', 0);
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_docs_file: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui processar o arquivo agora. Tente de novo.', 'kb', 'none', 'rid', 0);
END $f$;

-- ---------- acao principal (intent document_manage) ----------
-- req: {action,title,query,folder,folder_to,expires_on,alert_days,file_id}
-- devolve {text,kb,rid,files:[{file_id,tg_type,caption}]}; o n8n envia os files (um por item) e depois o text.
CREATE OR REPLACE FUNCTION agente.f_docs(p_user bigint, p_req jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE
  v_act text := lower(btrim(coalesce(p_req->>'action', '')));
  v_title text := btrim(coalesce(p_req->>'title', '')); v_q text := btrim(coalesce(p_req->>'query', ''));
  v_folder text := btrim(coalesce(p_req->>'folder', '')); v_to text := btrim(coalesce(p_req->>'folder_to', ''));
  v_exp date := f_safe_date(p_req->>'expires_on'); v_days integer := nullif(p_req->>'alert_days', '')::integer;
  v_fid bigint; v_ids bigint[]; v_files jsonb; v_txt text; v_n integer; v_cnt integer; d documents%ROWTYPE; fo doc_folders%ROWTYPE;
  v_names text; v_created boolean; v_tid bigint; v_lim integer; v_ex integer; v_tz text;
BEGIN
  IF p_user IS NULL THEN RETURN jsonb_build_object('text', 'Não consegui identificar você.', 'kb', 'none', 'rid', 0); END IF;
  SELECT timezone INTO v_tz FROM users WHERE id = p_user;
  IF v_act = '' THEN
    v_act := CASE WHEN v_exp IS NOT NULL THEN 'expiry_set' WHEN v_q <> '' THEN 'find' ELSE '' END;
  END IF;

  -- ===== guardar =====
  IF v_act = 'save' THEN
    RETURN f_docs_save(p_user, p_req);

  -- ===== criar pasta =====
  ELSIF v_act = 'create_folder' THEN
    IF v_folder = '' THEN v_folder := coalesce(nullif(v_to, ''), v_title); END IF;
    IF f_norm(v_folder) = '' THEN RETURN jsonb_build_object('text', 'Qual o nome da pasta?', 'kb', 'none', 'rid', 0); END IF;
    IF (SELECT count(*) FROM doc_folders WHERE user_id = p_user) >= 100 THEN
      RETURN jsonb_build_object('text', 'Você já tem 100 pastas, que é o limite. Apague alguma antes de criar outra.', 'kb', 'none', 'rid', 0);
    END IF;
    SELECT o_id, o_created INTO v_fid, v_created FROM f_doc_folder_ensure(p_user, v_folder);
    SELECT * INTO fo FROM doc_folders WHERE id = v_fid;
    RETURN jsonb_build_object('text', CASE WHEN v_created THEN 'Criei a pasta ' || fo.name || '. Para guardar nela, mande o arquivo e diga "guarda na pasta ' || fo.name || '".' ELSE 'Você já tem a pasta ' || fo.name || '.' END, 'kb', 'none', 'rid', 0);

  -- ===== listar pastas / conteudo de uma pasta =====
  ELSIF v_act = 'list_folders' THEN
    IF v_folder <> '' THEN
      v_fid := f_doc_folder_find(p_user, v_folder);
      IF v_fid IS NULL THEN
        RETURN jsonb_build_object('text', 'Não achei a pasta "' || v_folder || '".' || coalesce(E'\nSuas pastas: ' || (SELECT string_agg(name, ', ' ORDER BY name) FROM doc_folders WHERE user_id = p_user), ''), 'kb', 'none', 'rid', 0);
      END IF;
      SELECT * INTO fo FROM doc_folders WHERE id = v_fid AND user_id = p_user;
      SELECT count(*) INTO v_cnt FROM documents WHERE user_id = p_user AND folder_id = v_fid;
      IF v_cnt = 0 THEN RETURN jsonb_build_object('text', 'A pasta ' || fo.name || ' está vazia.', 'kb', 'none', 'rid', 0); END IF;
      SELECT string_agg('- ' || x.title || CASE WHEN x.expires_on IS NOT NULL THEN ' (vence ' || to_char(x.expires_on, 'DD/MM/YYYY') || ')' ELSE '' END, E'\n' ORDER BY x.created_at DESC)
        INTO v_names FROM (SELECT title, expires_on, created_at FROM documents WHERE user_id = p_user AND folder_id = v_fid ORDER BY created_at DESC LIMIT 25) x;
      RETURN jsonb_build_object('text', 'Pasta ' || fo.name || ' (' || v_cnt || CASE WHEN v_cnt = 1 THEN ' arquivo' ELSE ' arquivos' END || '):' || E'\n' || v_names
        || CASE WHEN v_cnt > 25 THEN E'\n... e mais ' || (v_cnt - 25) ELSE '' END || E'\nPara receber os arquivos, diga "me manda a pasta ' || fo.name || '".', 'kb', 'none', 'rid', 0);
    END IF;
    SELECT count(*) INTO v_cnt FROM documents WHERE user_id = p_user AND folder_id IS NULL;
    SELECT string_agg('- ' || f.name || ' (' || (SELECT count(*) FROM documents dd WHERE dd.folder_id = f.id AND dd.user_id = p_user) || ')', E'\n' ORDER BY f.name)
      INTO v_names FROM doc_folders f WHERE f.user_id = p_user;
    IF v_names IS NULL AND v_cnt = 0 THEN
      RETURN jsonb_build_object('text', 'Você ainda não guardou nada. Mande um arquivo ou foto e diga "guarda" (pode dizer a pasta).', 'kb', 'none', 'rid', 0);
    END IF;
    RETURN jsonb_build_object('text', 'Suas pastas:' || coalesce(E'\n' || v_names, E'\n(nenhuma pasta criada)') || CASE WHEN v_cnt > 0 THEN E'\nSem pasta: ' || v_cnt || CASE WHEN v_cnt = 1 THEN ' arquivo' ELSE ' arquivos' END ELSE '' END, 'kb', 'none', 'rid', 0);

  -- ===== achar (e mandar de volta) =====
  ELSIF v_act = 'find' THEN
    v_fid := CASE WHEN v_folder <> '' THEN f_doc_folder_find(p_user, v_folder) END;
    IF v_q = '' THEN v_q := v_title; END IF;
    IF v_q = '' AND v_folder <> '' THEN v_q := ''; END IF;
    IF v_folder <> '' AND v_fid IS NULL AND f_norm(v_q) = '' THEN
      v_q := v_folder;
    END IF;
    SELECT count(*) INTO v_cnt FROM f_doc_search(p_user, v_q, v_fid, 50) WHERE exact_hit;
    IF v_cnt > 0 THEN
      v_ex := 1;
    ELSE
      SELECT count(*) INTO v_cnt FROM f_doc_search(p_user, v_q, v_fid, 50);
      v_ex := 0;
    END IF;
    IF v_cnt = 0 THEN
      RETURN jsonb_build_object('text', 'Não achei nenhum arquivo parecido com "' || coalesce(nullif(v_q, ''), v_folder) || '". Diga "minhas pastas" para ver o que está guardado.', 'kb', 'none', 'rid', 0);
    END IF;
    SELECT jsonb_agg(jsonb_build_object('file_id', x.file_id, 'tg_type', x.tg_type, 'caption', f_doc_caption(x.title, x.fname)) ORDER BY x.ord),
           string_agg(x.title, ', ' ORDER BY x.ord) FILTER (WHERE x.ord > 3)
      INTO v_files, v_names
      FROM (SELECT d2.file_id, d2.tg_type, d2.title, fo2.name AS fname, row_number() OVER (ORDER BY s.exact_hit DESC, s.score DESC, d2.created_at DESC) AS ord
              FROM f_doc_search(p_user, v_q, v_fid, 50) s JOIN documents d2 ON d2.id = s.doc_id AND d2.user_id = p_user LEFT JOIN doc_folders fo2 ON fo2.id = d2.folder_id
             WHERE (v_ex = 0 OR s.exact_hit)) x;
    -- v_files so com os 3 primeiros
    v_files := (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM (SELECT e FROM jsonb_array_elements(v_files) WITH ORDINALITY t(e, i) WHERE i <= 3 ORDER BY i) q);
    RETURN jsonb_build_object('text',
      CASE WHEN v_ex = 1 THEN CASE WHEN v_cnt = 1 THEN 'Achei 1 arquivo.' ELSE 'Achei ' || v_cnt || ' arquivos' || CASE WHEN v_cnt > 3 THEN '; mandei os 3 mais recentes.' ELSE '.' END END
           ELSE 'Não achei exatamente, mas tem ' || v_cnt || CASE WHEN v_cnt = 1 THEN ' arquivo parecido' ELSE ' arquivos parecidos' END || CASE WHEN v_cnt > 3 THEN ' (mandei 3)' ELSE '' END || '.' END
      || CASE WHEN v_names IS NOT NULL THEN E'\nOutros: ' || v_names || E'.\nDiga o nome para eu mandar.' ELSE '' END,
      'kb', 'none', 'rid', 0, 'files', v_files);

  -- ===== mandar a pasta (ou tudo de uma busca) =====
  ELSIF v_act = 'send_folder' THEN
    IF v_folder = '' THEN v_folder := v_q; END IF;
    IF v_folder = '' THEN v_folder := v_title; END IF;
    v_fid := f_doc_folder_find(p_user, v_folder);
    v_lim := 10;
    IF v_fid IS NOT NULL THEN
      SELECT * INTO fo FROM doc_folders WHERE id = v_fid AND user_id = p_user;
      SELECT count(*) INTO v_cnt FROM documents WHERE user_id = p_user AND folder_id = v_fid;
      IF v_cnt = 0 THEN RETURN jsonb_build_object('text', 'A pasta ' || fo.name || ' está vazia.', 'kb', 'none', 'rid', 0); END IF;
      SELECT jsonb_agg(jsonb_build_object('file_id', x.file_id, 'tg_type', x.tg_type, 'caption', f_doc_caption(x.title, NULL)) ORDER BY x.created_at, x.id)
        INTO v_files FROM (SELECT id, file_id, tg_type, title, created_at FROM documents WHERE user_id = p_user AND folder_id = v_fid ORDER BY created_at DESC, id DESC LIMIT v_lim) x;
      RETURN jsonb_build_object('text', 'Pasta ' || fo.name || ': ' || CASE WHEN v_cnt > v_lim THEN 'mandei os ' || v_lim || ' mais recentes de ' || v_cnt || '.' WHEN v_cnt = 1 THEN 'mandei o único arquivo.' ELSE 'mandei os ' || v_cnt || ' arquivos.' END, 'kb', 'none', 'rid', 0, 'files', v_files);
    END IF;
    SELECT count(*) INTO v_cnt FROM f_doc_search(p_user, v_folder, NULL, 50) WHERE exact_hit;
    IF v_cnt = 0 THEN
      RETURN jsonb_build_object('text', 'Não achei uma pasta nem arquivos com "' || v_folder || '".' || coalesce(E'\nSuas pastas: ' || (SELECT string_agg(name, ', ' ORDER BY name) FROM doc_folders WHERE user_id = p_user), ''), 'kb', 'none', 'rid', 0);
    END IF;
    SELECT jsonb_agg(jsonb_build_object('file_id', x.file_id, 'tg_type', x.tg_type, 'caption', f_doc_caption(x.title, x.fname)) ORDER BY x.created_at, x.id)
      INTO v_files FROM (SELECT d2.id, d2.file_id, d2.tg_type, d2.title, d2.created_at, fo2.name AS fname
                           FROM f_doc_search(p_user, v_folder, NULL, v_lim) s JOIN documents d2 ON d2.id = s.doc_id AND d2.user_id = p_user LEFT JOIN doc_folders fo2 ON fo2.id = d2.folder_id
                          WHERE s.exact_hit) x;
    RETURN jsonb_build_object('text', 'Achei ' || v_cnt || CASE WHEN v_cnt = 1 THEN ' arquivo' ELSE ' arquivos' END || ' sobre "' || v_folder || '"' || CASE WHEN v_cnt > v_lim THEN '; mandei os ' || v_lim || ' mais relevantes.' ELSE '.' END, 'kb', 'none', 'rid', 0, 'files', v_files);

  -- ===== mover =====
  ELSIF v_act = 'move' THEN
    IF v_to = '' THEN v_to := v_folder; END IF;
    IF f_norm(v_to) = '' THEN RETURN jsonb_build_object('text', 'Para qual pasta eu movo?', 'kb', 'none', 'rid', 0); END IF;
    v_ids := f_doc_resolve(p_user, v_q, NULL, true);
    IF cardinality(v_ids) = 0 THEN RETURN jsonb_build_object('text', 'Não achei esse arquivo. Diga o nome dele (ou "minhas pastas" para ver o que está guardado).', 'kb', 'none', 'rid', 0); END IF;
    IF cardinality(v_ids) > 1 THEN
      RETURN jsonb_build_object('text', 'Achei mais de um:' || (SELECT string_agg(E'\n- ' || title, '' ORDER BY created_at DESC) FROM documents WHERE id = ANY (v_ids) AND user_id = p_user) || E'\nDiga o nome com mais detalhe.', 'kb', 'none', 'rid', 0);
    END IF;
    SELECT o_id, o_created INTO v_tid, v_created FROM f_doc_folder_ensure(p_user, v_to);
    UPDATE documents SET folder_id = v_tid WHERE id = v_ids[1] AND user_id = p_user RETURNING * INTO d;
    RETURN jsonb_build_object('text', 'Movi "' || d.title || '" para a pasta ' || (SELECT name FROM doc_folders WHERE id = v_tid) || CASE WHEN v_created THEN ' (criei a pasta).' ELSE '.' END, 'kb', 'none', 'rid', 0);

  -- ===== renomear (arquivo ou pasta) =====
  ELSIF v_act = 'rename' THEN
    IF v_q = '' AND v_folder <> '' THEN
      v_to := coalesce(nullif(v_to, ''), v_title);
      v_fid := f_doc_folder_find(p_user, v_folder);
      IF v_fid IS NULL THEN RETURN jsonb_build_object('text', 'Não achei a pasta "' || v_folder || '".', 'kb', 'none', 'rid', 0); END IF;
      IF f_norm(v_to) = '' THEN RETURN jsonb_build_object('text', 'Qual o novo nome da pasta?', 'kb', 'none', 'rid', 0); END IF;
      v_to := left(upper(left(btrim(v_to), 1)) || substr(btrim(v_to), 2), 60);
      IF EXISTS (SELECT 1 FROM doc_folders WHERE user_id = p_user AND name_norm = f_norm(v_to) AND id <> v_fid) THEN
        RETURN jsonb_build_object('text', 'Já existe uma pasta com o nome ' || v_to || '.', 'kb', 'none', 'rid', 0);
      END IF;
      UPDATE doc_folders SET name = v_to, name_norm = f_norm(v_to) WHERE id = v_fid AND user_id = p_user RETURNING * INTO fo;
      RETURN jsonb_build_object('text', 'Renomeei a pasta para ' || fo.name || '.', 'kb', 'none', 'rid', 0);
    END IF;
    IF v_title = '' THEN v_title := v_to; END IF;
    IF v_title = '' THEN RETURN jsonb_build_object('text', 'Qual o novo nome?', 'kb', 'none', 'rid', 0); END IF;
    v_ids := f_doc_resolve(p_user, v_q, NULL, true);
    IF cardinality(v_ids) = 0 THEN RETURN jsonb_build_object('text', 'Não achei esse arquivo. Diga o nome atual dele.', 'kb', 'none', 'rid', 0); END IF;
    IF cardinality(v_ids) > 1 THEN
      RETURN jsonb_build_object('text', 'Achei mais de um:' || (SELECT string_agg(E'\n- ' || title, '' ORDER BY created_at DESC) FROM documents WHERE id = ANY (v_ids) AND user_id = p_user) || E'\nDiga o nome atual com mais detalhe.', 'kb', 'none', 'rid', 0);
    END IF;
    SELECT * INTO d FROM documents WHERE id = v_ids[1] AND user_id = p_user;
    UPDATE documents SET title = left(v_title, 80) WHERE id = d.id AND user_id = p_user;
    IF d.reminder_id IS NOT NULL AND d.expires_on IS NOT NULL THEN
      UPDATE reminders SET title = 'Vencimento: ' || left(v_title, 80) || ' (vence em ' || to_char(d.expires_on, 'DD/MM/YYYY') || ')' WHERE id = d.reminder_id AND status = 'pending';
    END IF;
    RETURN jsonb_build_object('text', 'Renomeei "' || d.title || '" para "' || left(v_title, 80) || '".', 'kb', 'none', 'rid', 0);

  -- ===== apagar (com confirmacao) =====
  ELSIF v_act = 'delete' THEN
    IF v_q = '' AND v_folder <> '' THEN
      v_fid := f_doc_folder_find(p_user, v_folder);
      IF v_fid IS NULL THEN RETURN jsonb_build_object('text', 'Não achei a pasta "' || v_folder || '".', 'kb', 'none', 'rid', 0); END IF;
      SELECT * INTO fo FROM doc_folders WHERE id = v_fid AND user_id = p_user;
      SELECT count(*) INTO v_cnt FROM documents WHERE user_id = p_user AND folder_id = v_fid;
      RETURN jsonb_build_object('text', 'Apago a pasta ' || fo.name || '?' || CASE WHEN v_cnt > 0 THEN ' Os ' || v_cnt || ' arquivos dela continuam guardados, só ficam sem pasta.' ELSE '' END, 'kb', 'dc_fdel', 'rid', v_fid);
    END IF;
    IF cardinality(f_doc_tokens(v_q)) = 0 THEN RETURN jsonb_build_object('text', 'Qual arquivo eu apago? Diga o nome dele.', 'kb', 'none', 'rid', 0); END IF;
    v_ids := f_doc_resolve(p_user, v_q, NULL, false);
    IF cardinality(v_ids) = 0 THEN RETURN jsonb_build_object('text', 'Não achei esse arquivo.', 'kb', 'none', 'rid', 0); END IF;
    IF cardinality(v_ids) > 1 THEN
      RETURN jsonb_build_object('text', 'Achei mais de um:' || (SELECT string_agg(E'\n- ' || title, '' ORDER BY created_at DESC) FROM documents WHERE id = ANY (v_ids) AND user_id = p_user) || E'\nDiga o nome com mais detalhe para eu apagar o certo.', 'kb', 'none', 'rid', 0);
    END IF;
    SELECT * INTO d FROM documents WHERE id = v_ids[1] AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Apago "' || d.title || '"? Isso tira o arquivo da sua lista' || CASE WHEN d.expires_on IS NOT NULL THEN ' e cancela o aviso de vencimento' ELSE '' END || '.', 'kb', 'dc_del', 'rid', d.id);

  -- ===== validade + aviso =====
  ELSIF v_act = 'expiry_set' THEN
    IF v_exp IS NULL THEN RETURN jsonb_build_object('text', 'Quando ele vence? Me diga a data, por exemplo: "vence em 30/11/2026".', 'kb', 'none', 'rid', 0); END IF;
    v_ids := f_doc_resolve(p_user, coalesce(nullif(v_q, ''), v_title), NULL, true);
    IF cardinality(v_ids) = 0 THEN RETURN jsonb_build_object('text', 'Não achei esse documento. Guarde primeiro (mande o arquivo e diga "guarda") ou diga o nome dele.', 'kb', 'none', 'rid', 0); END IF;
    IF cardinality(v_ids) > 1 THEN
      RETURN jsonb_build_object('text', 'Achei mais de um:' || (SELECT string_agg(E'\n- ' || title, '' ORDER BY created_at DESC) FROM documents WHERE id = ANY (v_ids) AND user_id = p_user) || E'\nDiga o nome com mais detalhe.', 'kb', 'none', 'rid', 0);
    END IF;
    RETURN jsonb_build_object('text', f_doc_expiry_apply(p_user, v_ids[1], v_exp, coalesce(v_days, 7)), 'kb', 'none', 'rid', 0);
  END IF;

  RETURN jsonb_build_object('text', 'Não entendi o que fazer com o arquivo. Exemplos: "guarda essa foto na pasta Casa", "acha a apólice do carro", "me manda tudo da reforma", "minhas pastas", "me avisa antes do alvará vencer".', 'kb', 'none', 'rid', 0);
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_docs: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui agora. Tente de novo.', 'kb', 'none', 'rid', 0);
END $f$;

-- ---------- botoes dc* ----------
CREATE OR REPLACE FUNCTION agente.f_docs_cb(p_user bigint, p_data text)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente','public' AS $f$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint; d documents%ROWTYPE; fo doc_folders%ROWTYPE; v_cnt integer;
BEGIN
  BEGIN v_id := nullif(split_part(p_data, ':', 2), '')::bigint; EXCEPTION WHEN others THEN v_id := NULL; END;
  IF a = 'dckeep' THEN RETURN jsonb_build_object('text', 'Ok, mantive.', 'kb', 'none'); END IF;
  IF a = 'dcdel' THEN
    SELECT * INTO d FROM documents WHERE id = v_id AND user_id = p_user;
    IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Esse arquivo já foi apagado.', 'kb', 'none'); END IF;
    PERFORM f_doc_unremind(d.id);
    DELETE FROM documents WHERE id = d.id AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Apaguei "' || d.title || '".', 'kb', 'none');
  END IF;
  IF a = 'dcfdel' THEN
    SELECT * INTO fo FROM doc_folders WHERE id = v_id AND user_id = p_user;
    IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Essa pasta já foi apagada.', 'kb', 'none'); END IF;
    SELECT count(*) INTO v_cnt FROM documents WHERE folder_id = fo.id AND user_id = p_user;
    DELETE FROM doc_folders WHERE id = fo.id AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Apaguei a pasta ' || fo.name || '.' || CASE WHEN v_cnt > 0 THEN ' Os ' || v_cnt || ' arquivos continuam guardados, sem pasta.' ELSE '' END, 'kb', 'none');
  END IF;
  RETURN jsonb_build_object('text', 'Não entendi esse botão.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_docs_cb: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui agora. Tente de novo.', 'kb', 'none');
END $f$;

-- Fase 4: album = arquivos recebidos em ate 8 s (antes 30 s) entram no mesmo 'guarda'.
CREATE OR REPLACE FUNCTION agente.f_docs_save(p_user bigint, p_req jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'agente', 'public'
AS $function$
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
                  AND (id = a.id OR (coalesce(p_req->>'single', '') <> 'true' AND abs(extract(epoch FROM received_at - a.received_at)) <= 8))
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
END $function$;

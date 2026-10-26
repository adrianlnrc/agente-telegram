-- Fase 3: contatos, grupos e convites por frase; pendencia de convite/Meet para a agenda.
-- Idempotente. Depende de 007_contatos.sql (tabelas contacts, contact_groups, contact_group_members)
-- e de 012_base_agenda.sql (agenda_pending). Quem executa o botao de convite e a agenda (f_agenda_cb 'agok').
SET search_path TO agente, public;

-- Pendencias de confirmacao de contatos/grupos (remocao).
CREATE TABLE IF NOT EXISTS contact_pending (
  id          bigserial PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('remove_contact','remove_group')),
  target_id   bigint,
  target_name text NOT NULL DEFAULT '',
  state       text NOT NULL DEFAULT 'open' CHECK (state IN ('open','done','cancelled')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS contact_pending_user ON contact_pending (user_id, state);

-- ---------- auxiliares ----------
-- Acha um contato pelo nome (sem acento/caixa; ou unico que comece com o nome citado).
CREATE OR REPLACE FUNCTION f_ct_find(p_user bigint, p_name text) RETURNS bigint
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE n text := f_norm(p_name); v bigint; k int;
BEGIN
  IF n = '' THEN RETURN NULL; END IF;
  SELECT id INTO v FROM contacts WHERE user_id = p_user AND f_norm(name) = n ORDER BY id LIMIT 1;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT count(*), min(id) INTO k, v FROM contacts WHERE user_id = p_user AND f_norm(name) LIKE n || ' %';
  IF k = 1 THEN RETURN v; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION f_ct_group_find(p_user bigint, p_name text) RETURNS bigint
LANGUAGE sql STABLE SET search_path TO 'agente','public' AS $$
  SELECT id FROM contact_groups WHERE user_id = p_user AND f_norm(name) = f_norm(p_name) AND f_norm(p_name) <> '' ORDER BY id LIMIT 1;
$$;

-- Nome para exibir (primeira letra de cada palavra maiuscula).
CREATE OR REPLACE FUNCTION f_ct_disp(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT COALESCE((SELECT string_agg(upper(left(w, 1)) || substr(w, 2), ' ' ORDER BY o)
                   FROM unnest(string_to_array(trim(COALESCE(p, '')), ' ')) WITH ORDINALITY AS t(w, o) WHERE w <> ''), '');
$$;

-- "da Cláudia" / "do Douglas"
CREATE OR REPLACE FUNCTION f_ct_de(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT CASE WHEN right(f_norm(split_part(trim(COALESCE(p, '')), ' ', 1)), 1) = 'a' THEN 'da ' ELSE 'do ' END || f_ct_disp(p);
$$;

-- ISO 8601 com o deslocamento do fuso do usuario (ex. 2026-10-30T16:00:00-03:00)
CREATE OR REPLACE FUNCTION f_ct_iso(p timestamptz, p_tz text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT to_char(p AT TIME ZONE p_tz, 'YYYY-MM-DD"T"HH24:MI:SS')
    || CASE WHEN o < interval '0' THEN '-' ELSE '+' END
    || lpad((abs(extract(epoch FROM o))::int / 3600)::text, 2, '0') || ':' || lpad(((abs(extract(epoch FROM o))::int % 3600) / 60)::text, 2, '0')
  FROM (SELECT (p AT TIME ZONE p_tz) - (p AT TIME ZONE 'UTC') AS o) x;
$$;

-- ---------- f_group_save e f_resolve_invitees: agora comparam sem acento ----------
CREATE OR REPLACE FUNCTION f_group_save(p_user bigint, p_group text, p_names text[])
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE g bigint; n text; cid bigint; missing text[] := '{}'; added text[] := '{}'; cname text;
BEGIN
  g := f_ct_group_find(p_user, p_group);
  IF g IS NULL THEN
    INSERT INTO contact_groups(user_id, name) VALUES (p_user, lower(trim(p_group)))
    ON CONFLICT (user_id, name) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO g;
  END IF;
  DELETE FROM contact_group_members WHERE group_id = g;
  FOREACH n IN ARRAY COALESCE(p_names, '{}') LOOP
    IF trim(COALESCE(n, '')) = '' THEN CONTINUE; END IF;
    cid := f_ct_find(p_user, n);
    IF cid IS NULL THEN
      IF NOT (lower(trim(n)) = ANY (missing)) THEN missing := missing || lower(trim(n)); END IF;
    ELSE
      INSERT INTO contact_group_members VALUES (g, cid) ON CONFLICT DO NOTHING;
      SELECT name INTO cname FROM contacts WHERE id = cid;
      IF NOT (cname = ANY (added)) THEN added := added || cname; END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'group', (SELECT name FROM contact_groups WHERE id = g), 'members', to_jsonb(added), 'missing', to_jsonb(missing));
END $$;

CREATE OR REPLACE FUNCTION f_resolve_invitees(p_user bigint, p_names text[])
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE n text; found jsonb := '[]'; unknown text[] := '{}'; g bigint; cid bigint;
BEGIN
  FOREACH n IN ARRAY COALESCE(p_names, '{}') LOOP
    n := lower(trim(COALESCE(n, '')));
    IF n = '' THEN CONTINUE; END IF;
    g := f_ct_group_find(p_user, n);
    IF g IS NOT NULL THEN
      found := found || COALESCE((SELECT jsonb_agg(jsonb_build_object('name', c.name, 'email', c.email) ORDER BY c.name)
        FROM contact_group_members m JOIN contacts c ON c.id = m.contact_id WHERE m.group_id = g), '[]'::jsonb);
      CONTINUE;
    END IF;
    cid := f_ct_find(p_user, n);
    IF cid IS NOT NULL THEN
      found := found || (SELECT jsonb_build_array(jsonb_build_object('name', name, 'email', email)) FROM contacts WHERE id = cid);
    ELSIF n ~ '^[^@ ]+@[^@ ]+\.[^@ ]+$' THEN
      found := found || jsonb_build_array(jsonb_build_object('name', n, 'email', n));
    ELSE unknown := unknown || n; END IF;
  END LOOP;
  RETURN jsonb_build_object('invitees', found, 'unknown', to_jsonb(unknown));
END $$;

-- ---------- f_contacts: contatos e grupos por frase ----------
-- p: {contact_action, contact_name, contact_email, group_name, group_members[], text}
CREATE OR REPLACE FUNCTION f_contacts(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  act text := lower(COALESCE(p->>'contact_action', ''));
  nm text := trim(COALESCE(p->>'contact_name', ''));
  em text := lower(trim(COALESCE(p->>'contact_email', '')));
  gn text := trim(COALESCE(p->>'group_name', ''));
  txt text := COALESCE(p->>'text', '');
  members text[] := COALESCE(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'group_members') = 'array' THEN p->'group_members' ELSE '[]'::jsonb END)), '{}');
  fav boolean := NULL;
  cid bigint; gid bigint; c contacts%ROWTYPE; r jsonb; pid bigint; v_old text; lst text; cur text[]; miss text[]; i int; line text; cnt int;
BEGIN
  -- limpa membros vazios
  members := ARRAY(SELECT trim(x) FROM unnest(members) x WHERE trim(x) <> '');
  IF act = '' THEN
    IF gn <> '' AND array_length(members, 1) > 0 THEN act := 'group_save';
    ELSIF gn <> '' THEN act := 'group_list';
    ELSIF nm <> '' AND em <> '' THEN act := 'save';
    ELSE act := 'list'; END IF;
  END IF;
  -- favorito pela frase
  IF txt ~* 'favorit' THEN
    fav := NOT (txt ~* '(nao|não)[ ]+(e|é|eh|seja|mais)?[ ]*(mais[ ]+)?(a |o )?favorit|(tira|tirar|remove|remover|retira|retirar|desmarca|desmarcar)[^.]*favorit|desfavorit');
  END IF;
  -- "tira a Bia dos favoritos" nunca apaga o contato
  IF act = 'remove' AND fav IS NOT NULL THEN act := 'save'; END IF;

  IF act = 'save' THEN
    IF nm = '' AND em <> '' THEN
      RETURN jsonb_build_object('text', 'De quem é o e-mail ' || em || '? Diga: o e-mail da Cláudia é ' || em, 'kb', 'none', 'rid', 0);
    END IF;
    IF nm = '' THEN
      RETURN jsonb_build_object('text', 'Qual contato? Diga, por exemplo: o e-mail da Cláudia é claudia@dominio.com', 'kb', 'none', 'rid', 0);
    END IF;
    cid := f_ct_find(p_user, nm);
    IF em = '' THEN
      IF cid IS NULL THEN
        RETURN jsonb_build_object('text', 'Não tenho o e-mail de ' || f_ct_disp(nm) || '. Diga: o e-mail ' || f_ct_de(nm) || ' é fulano@dominio.com', 'kb', 'none', 'rid', 0);
      END IF;
      IF fav IS NULL THEN
        SELECT * INTO c FROM contacts WHERE id = cid;
        RETURN jsonb_build_object('text', f_ct_disp(c.name) || ' já está nos contatos (' || c.email || '). Para trocar o e-mail, diga o novo.', 'kb', 'none', 'rid', 0);
      END IF;
      UPDATE contacts SET favorite = fav WHERE id = cid RETURNING * INTO c;
      RETURN jsonb_build_object('text', CASE WHEN fav THEN f_ct_disp(c.name) || ' agora é favorito: vem primeiro na lista.' ELSE f_ct_disp(c.name) || ' saiu dos favoritos.' END, 'kb', 'none', 'rid', 0);
    END IF;
    IF em !~ '^[^@ ]+@[^@ ]+\.[^@ ]+$' THEN
      RETURN jsonb_build_object('text', 'Esse e-mail não parece válido (' || em || '). Pode conferir e mandar de novo?', 'kb', 'none', 'rid', 0);
    END IF;
    IF cid IS NOT NULL THEN
      SELECT email INTO v_old FROM contacts WHERE id = cid;
      UPDATE contacts SET email = em, favorite = COALESCE(fav, favorite) WHERE id = cid RETURNING * INTO c;
      RETURN jsonb_build_object('text', CASE WHEN v_old = em THEN 'Já estava salvo: ' ELSE 'Atualizei: ' END || f_ct_disp(c.name) || ', ' || c.email || CASE WHEN c.favorite THEN ' (favorito)' ELSE '' END || '.', 'kb', 'none', 'rid', 0);
    END IF;
    r := f_contact_save(p_user, nm, em, fav);
    IF NOT COALESCE((r->>'ok')::boolean, false) THEN
      RETURN jsonb_build_object('text', 'Não consegui salvar esse contato. Confira o e-mail e tente de novo.', 'kb', 'none', 'rid', 0);
    END IF;
    RETURN jsonb_build_object('text', 'Contato salvo: ' || f_ct_disp(r->>'name') || ', ' || (r->>'email') || CASE WHEN (r->>'favorite')::boolean THEN ' (favorito)' ELSE '' END || '.', 'kb', 'none', 'rid', 0);

  ELSIF act = 'list' THEN
    SELECT count(*) INTO cnt FROM contacts WHERE user_id = p_user;
    IF cnt = 0 THEN
      RETURN jsonb_build_object('text', 'Você ainda não salvou contatos. Diga, por exemplo: o e-mail da Cláudia é claudia@dominio.com', 'kb', 'none', 'rid', 0);
    END IF;
    lst := '';
    FOR c IN SELECT * FROM contacts WHERE user_id = p_user AND (NOT (txt ~* 'favorit') OR favorite OR NOT EXISTS (SELECT 1 FROM contacts x WHERE x.user_id = p_user AND x.favorite))
             ORDER BY favorite DESC, name LOOP
      lst := lst || E'\n- ' || f_ct_disp(c.name) || ': ' || c.email || CASE WHEN c.favorite THEN ' (favorito)' ELSE '' END
        || COALESCE((SELECT ' [grupos: ' || string_agg(g.name, ', ' ORDER BY g.name) || ']'
                     FROM contact_group_members m JOIN contact_groups g ON g.id = m.group_id WHERE m.contact_id = c.id), '');
    END LOOP;
    RETURN jsonb_build_object('text', 'Seus contatos:' || lst, 'kb', 'none', 'rid', 0);

  ELSIF act = 'remove' THEN
    cid := f_ct_find(p_user, nm);
    IF cid IS NULL THEN
      RETURN jsonb_build_object('text', CASE WHEN nm = '' THEN 'Qual contato você quer tirar?' ELSE 'Não encontrei ' || f_ct_disp(nm) || ' nos contatos.' END, 'kb', 'none', 'rid', 0);
    END IF;
    SELECT * INTO c FROM contacts WHERE id = cid;
    SELECT id INTO pid FROM contact_pending WHERE user_id = p_user AND kind = 'remove_contact' AND target_id = cid AND state = 'open' AND created_at > now() - interval '1 hour' ORDER BY id DESC LIMIT 1;
    IF pid IS NULL THEN
      INSERT INTO contact_pending(user_id, kind, target_id, target_name) VALUES (p_user, 'remove_contact', cid, c.name) RETURNING id INTO pid;
    END IF;
    RETURN jsonb_build_object('text', 'Tirar ' || f_ct_disp(c.name) || ' (' || c.email || ') dos contatos? Ele também sai dos grupos.', 'kb', 'ct_confirm', 'rid', pid);

  ELSIF act = 'group_save' THEN
    IF gn = '' THEN
      RETURN jsonb_build_object('text', 'Qual o nome do grupo? Diga, por exemplo: cria o grupo time com Douglas, Bia e Cláudia', 'kb', 'none', 'rid', 0);
    END IF;
    IF array_length(members, 1) IS NULL THEN
      RETURN jsonb_build_object('text', 'Quem entra no grupo ' || lower(gn) || '? Diga os nomes, por exemplo: cria o grupo ' || lower(gn) || ' com Douglas e Bia', 'kb', 'none', 'rid', 0);
    END IF;
    gid := f_ct_group_find(p_user, gn);
    IF gid IS NOT NULL AND txt ~* '(adiciona|adicionar|coloca|colocar|inclui|incluir|poe|põe|por )' AND txt !~* '(tira|tirar|remove|remover|retira|retirar)' THEN
      cur := ARRAY(SELECT c2.name FROM contact_group_members m JOIN contacts c2 ON c2.id = m.contact_id WHERE m.group_id = gid);
      members := cur || members;
    ELSIF gid IS NOT NULL AND txt ~* '(tira|tirar|remove|remover|retira|retirar)' THEN
      cur := ARRAY(SELECT c2.name FROM contact_group_members m JOIN contacts c2 ON c2.id = m.contact_id WHERE m.group_id = gid
                   AND NOT EXISTS (SELECT 1 FROM unnest(members) x WHERE f_ct_find(p_user, x) = c2.id));
      members := cur;
    END IF;
    r := f_group_save(p_user, gn, members);
    miss := COALESCE(ARRAY(SELECT jsonb_array_elements_text(r->'missing')), '{}');
    cur := COALESCE(ARRAY(SELECT jsonb_array_elements_text(r->'members')), '{}');
    line := 'Grupo ' || (r->>'group') || ': ' || CASE WHEN array_length(cur, 1) IS NULL THEN 'sem ninguém por enquanto' ELSE (SELECT string_agg(f_ct_disp(x), ', ') FROM unnest(cur) x) END || '.';
    IF array_length(miss, 1) > 0 THEN
      line := line || E'\nNão tenho cadastro de ' || (SELECT string_agg(f_ct_disp(x), ', ') FROM unnest(miss) x)
        || '. Diga: o e-mail ' || f_ct_de(miss[1]) || ' é fulano@dominio.com, e depois peça o grupo de novo.';
    END IF;
    RETURN jsonb_build_object('text', line, 'kb', 'none', 'rid', 0);

  ELSIF act = 'group_list' THEN
    IF gn <> '' THEN
      gid := f_ct_group_find(p_user, gn);
      IF gid IS NULL THEN
        RETURN jsonb_build_object('text', 'Não encontrei o grupo ' || lower(gn) || '.', 'kb', 'none', 'rid', 0);
      END IF;
      SELECT 'Grupo ' || g.name || ': ' || COALESCE((SELECT string_agg(f_ct_disp(c2.name) || ' (' || c2.email || ')', ', ' ORDER BY c2.name)
              FROM contact_group_members m JOIN contacts c2 ON c2.id = m.contact_id WHERE m.group_id = g.id), 'ninguém ainda') || '.'
        INTO line FROM contact_groups g WHERE g.id = gid;
      RETURN jsonb_build_object('text', line, 'kb', 'none', 'rid', 0);
    END IF;
    SELECT count(*) INTO cnt FROM contact_groups WHERE user_id = p_user;
    IF cnt = 0 THEN
      RETURN jsonb_build_object('text', 'Você ainda não tem grupos. Diga, por exemplo: cria o grupo time com Douglas, Bia e Cláudia', 'kb', 'none', 'rid', 0);
    END IF;
    lst := '';
    FOR gid, v_old IN SELECT g.id, g.name FROM contact_groups g WHERE g.user_id = p_user ORDER BY g.name LOOP
      lst := lst || E'\n- ' || v_old || ': ' || COALESCE((SELECT string_agg(f_ct_disp(c2.name), ', ' ORDER BY c2.name)
              FROM contact_group_members m JOIN contacts c2 ON c2.id = m.contact_id WHERE m.group_id = gid), 'ninguém ainda');
    END LOOP;
    RETURN jsonb_build_object('text', 'Seus grupos:' || lst, 'kb', 'none', 'rid', 0);

  ELSIF act = 'group_remove' THEN
    gid := f_ct_group_find(p_user, gn);
    IF gid IS NULL THEN
      RETURN jsonb_build_object('text', CASE WHEN gn = '' THEN 'Qual grupo você quer apagar?' ELSE 'Não encontrei o grupo ' || lower(gn) || '.' END, 'kb', 'none', 'rid', 0);
    END IF;
    SELECT name INTO v_old FROM contact_groups WHERE id = gid;
    SELECT id INTO pid FROM contact_pending WHERE user_id = p_user AND kind = 'remove_group' AND target_id = gid AND state = 'open' AND created_at > now() - interval '1 hour' ORDER BY id DESC LIMIT 1;
    IF pid IS NULL THEN
      INSERT INTO contact_pending(user_id, kind, target_id, target_name) VALUES (p_user, 'remove_group', gid, v_old) RETURNING id INTO pid;
    END IF;
    RETURN jsonb_build_object('text', 'Apagar o grupo ' || v_old || '? Os contatos continuam salvos.', 'kb', 'ct_confirm', 'rid', pid);
  END IF;

  RETURN jsonb_build_object('text', 'Não entendi o que fazer com os contatos. Exemplos: "meus contatos", "salva o e-mail da Cláudia: claudia@dominio.com", "cria o grupo time com Douglas e Bia".', 'kb', 'none', 'rid', 0);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('text', 'Não consegui mexer nos contatos agora. Tente de novo em instantes.', 'kb', 'none', 'rid', 0);
END $$;

-- ---------- f_contacts_cb: botoes ctok / ctno ----------
CREATE OR REPLACE FUNCTION f_contacts_cb(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint; pd contact_pending%ROWTYPE; n int;
BEGIN
  BEGIN v_id := NULLIF(split_part(p_data, ':', 2), '')::bigint; EXCEPTION WHEN OTHERS THEN v_id := NULL; END;
  IF a NOT IN ('ctok', 'ctno') OR v_id IS NULL THEN
    RETURN jsonb_build_object('text', 'Não entendi esse botão.', 'kb', 'none', 'rid', 0);
  END IF;
  SELECT * INTO pd FROM contact_pending WHERE id = v_id AND user_id = p_user FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não encontrei essa confirmação.', 'kb', 'none', 'rid', 0); END IF;
  IF pd.state <> 'open' THEN RETURN jsonb_build_object('text', 'Essa confirmação já foi respondida.', 'kb', 'none', 'rid', 0); END IF;
  IF a = 'ctno' THEN
    UPDATE contact_pending SET state = 'cancelled' WHERE id = v_id;
    RETURN jsonb_build_object('text', 'Ok, mantive ' || CASE WHEN pd.kind = 'remove_group' THEN 'o grupo ' || pd.target_name ELSE f_ct_disp(pd.target_name) END || '.', 'kb', 'none', 'rid', 0);
  END IF;
  IF pd.kind = 'remove_contact' THEN
    DELETE FROM contacts WHERE id = pd.target_id AND user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE contact_pending SET state = 'done' WHERE id = v_id;
    RETURN jsonb_build_object('text', CASE WHEN n > 0 THEN 'Pronto, tirei ' || f_ct_disp(pd.target_name) || ' dos contatos.' ELSE f_ct_disp(pd.target_name) || ' já não estava nos contatos.' END, 'kb', 'none', 'rid', 0);
  ELSE
    DELETE FROM contact_groups WHERE id = pd.target_id AND user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE contact_pending SET state = 'done' WHERE id = v_id;
    RETURN jsonb_build_object('text', CASE WHEN n > 0 THEN 'Pronto, apaguei o grupo ' || pd.target_name || '.' ELSE 'O grupo ' || pd.target_name || ' já não existia.' END, 'kb', 'none', 'rid', 0);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('text', 'Não consegui concluir agora. Tente de novo.', 'kb', 'none', 'rid', 0);
END $$;

-- ---------- f_invite_prepare: compromisso com convidados e/ou link do Meet ----------
-- p: {summary, start, end, location, meet, repeat_freq, repeat_until, repeat_count, lead_str, source, invitees[]}
-- Cria agenda_pending kind='create' e pede confirmacao (ag_confirm); quem executa e o agente de agenda (agok).
CREATE OR REPLACE FUNCTION f_invite_prepare(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  u users%ROWTYPE;
  names text[] := COALESCE(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'invitees') = 'array' THEN p->'invitees' ELSE '[]'::jsonb END)), '{}');
  v_meet boolean := COALESCE((p->>'meet')::boolean, false);
  v_start timestamptz; v_end timestamptz; v_title text;
  res jsonb; unk text[]; emails text; shown text; ex text; pid bigint; pl jsonb; lbl text; tzn text;
  wd text[] := ARRAY['dom','seg','ter','qua','qui','sex','sáb'];
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não achei seu cadastro.', 'kb', 'none', 'rid', 0); END IF;
  IF COALESCE(u.calendar_key, '') = '' THEN
    RETURN jsonb_build_object('text', 'Seu Google Agenda não está conectado, então não consigo enviar convites nem criar link do Meet.', 'kb', 'none', 'rid', 0);
  END IF;
  tzn := COALESCE(NULLIF(u.timezone, ''), 'America/Sao_Paulo');
  BEGIN
    v_start := NULLIF(p->>'start', '')::timestamptz;
    v_end := COALESCE(NULLIF(p->>'end', '')::timestamptz, v_start + interval '1 hour');
  EXCEPTION WHEN OTHERS THEN v_start := NULL;
  END;
  IF v_start IS NULL THEN
    RETURN jsonb_build_object('text', 'Não entendi o dia e a hora. Pode repetir?', 'kb', 'none', 'rid', 0);
  END IF;
  v_title := COALESCE(NULLIF(trim(p->>'summary'), ''), 'Reunião');

  res := f_resolve_invitees(p_user, names);
  unk := COALESCE(ARRAY(SELECT jsonb_array_elements_text(res->'unknown')), '{}');
  IF array_length(unk, 1) > 0 THEN
    RETURN jsonb_build_object('text', 'Não tenho o e-mail de ' || (SELECT string_agg(f_ct_disp(x), ' e ') FROM unnest(unk) x)
      || '. Diga: o e-mail ' || f_ct_de(unk[1]) || ' é fulano@dominio.com', 'kb', 'none', 'rid', 0);
  END IF;
  IF array_length(names, 1) > 0 AND jsonb_array_length(res->'invitees') = 0 THEN
    RETURN jsonb_build_object('text', 'Não encontrei ninguém para convidar (o grupo está vazio?). Veja com "meus grupos".', 'kb', 'none', 'rid', 0);
  END IF;
  -- sem repetir e-mail
  SELECT string_agg(e, ',' ORDER BY o), string_agg(nm, ', ' ORDER BY o)
    INTO emails, shown
  FROM (SELECT DISTINCT ON (x->>'email') x->>'email' AS e,
               CASE WHEN x->>'name' = x->>'email' THEN x->>'email' ELSE f_ct_disp(x->>'name') END AS nm, o
        FROM jsonb_array_elements(res->'invitees') WITH ORDINALITY t(x, o) ORDER BY x->>'email', o) d;

  pl := jsonb_build_object('summary', v_title, 'start', f_ct_iso(v_start, tzn),
        'end', f_ct_iso(v_end, tzn),
        'location', COALESCE(p->>'location', ''), 'attendees', COALESCE(emails, ''), 'meet', v_meet,
        'repeat_freq', COALESCE(p->>'repeat_freq', ''), 'repeat_until', COALESCE(p->>'repeat_until', ''),
        'repeat_count', COALESCE(NULLIF(p->>'repeat_count', '')::int, 0),
        'lead_str', COALESCE(p->>'lead_str', ''), 'source', COALESCE(NULLIF(p->>'source', ''), 'text'), 'force', false);
  IF (pl->>'repeat_count')::int = 0 THEN pl := jsonb_set(pl, '{repeat_count}', '""'::jsonb); END IF;

  -- idempotencia: mesma pendencia aberta recente
  SELECT id INTO pid FROM agenda_pending
   WHERE user_id = p_user AND kind = 'create' AND state = 'open' AND created_at > now() - interval '30 minutes'
     AND new_start = v_start AND title = v_title AND payload->>'attendees' = COALESCE(emails, '')
     AND (payload->>'meet')::boolean = v_meet
   ORDER BY id DESC LIMIT 1;
  IF pid IS NULL THEN
    INSERT INTO agenda_pending(user_id, kind, calendar_key, title, new_start, new_end, payload)
    VALUES (p_user, 'create', u.calendar_key, v_title, v_start, v_end, pl) RETURNING id INTO pid;
  END IF;

  lbl := wd[extract(dow FROM v_start AT TIME ZONE tzn)::int + 1] || ' ' || to_char(v_start AT TIME ZONE tzn, 'DD/MM') || ' às ' || to_char(v_start AT TIME ZONE tzn, 'HH24:MI');
  ex := 'Marcar ' || v_title || ' ' || lbl;
  IF shown IS NOT NULL THEN ex := ex || ' e enviar convite para ' || shown; END IF;
  IF v_meet THEN ex := ex || ' (com link do Meet)'; END IF;
  RETURN jsonb_build_object('text', ex || '?', 'kb', 'ag_confirm', 'rid', pid);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('text', 'Não consegui preparar o convite agora. Tente de novo em instantes.', 'kb', 'none', 'rid', 0);
END $$;

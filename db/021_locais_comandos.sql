-- Fase 4b: locais salvos ("igreja"), /contatos, /config completo e convite que mostra grupo e local.
-- Idempotente. Depende de 007_contatos.sql, 014_contatos_convites.sql e 017/016/015 (contagens do /config).
SET search_path TO agente, public;

-- ---------- locais salvos ----------
CREATE TABLE IF NOT EXISTS places (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  norm_name  text NOT NULL,
  address    text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, norm_name)
);

-- Acha o local pelo nome (sem acento/caixa; tira "a/o/da/do/na/no" iniciais: "a igreja" = "igreja").
CREATE OR REPLACE FUNCTION f_place_find(p_user bigint, p_name text) RETURNS bigint
LANGUAGE sql STABLE SET search_path TO 'agente','public' AS $$
  SELECT id FROM places
   WHERE user_id = p_user
     AND norm_name = regexp_replace(f_norm(coalesce(p_name, '')), '^(a|o|na|no|da|do|de|em) ', '')
     AND f_norm(coalesce(p_name, '')) <> ''
   ORDER BY id LIMIT 1;
$$;

-- p: {act: place_save|place_list|place_remove, name, address}
CREATE OR REPLACE FUNCTION f_places(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  act text := lower(coalesce(p->>'act', ''));
  nm text := btrim(regexp_replace(btrim(coalesce(p->>'name', '')), '^(a|o|na|no|da|do|de|em) ', '', 'i'));
  ad text := btrim(coalesce(p->>'address', ''));
  v_id bigint; t text; r record; n integer := 0;
BEGIN
  IF act = 'place_list' THEN
    FOR r IN SELECT name, address FROM places WHERE user_id = p_user ORDER BY name LOOP
      n := n + 1; t := coalesce(t, '') || E'\n- ' || r.name || ': ' || r.address;
    END LOOP;
    IF n = 0 THEN
      RETURN jsonb_build_object('text', 'Você ainda não salvou nenhum local. Ex.: "o local igreja é Rua das Flores, 120".', 'kb', 'none', 'rid', 0);
    END IF;
    RETURN jsonb_build_object('text', 'Seus locais:' || t, 'kb', 'none', 'rid', 0);
  END IF;
  IF nm = '' THEN
    RETURN jsonb_build_object('text', 'Qual o nome do local? Ex.: "o local igreja é Rua das Flores, 120".', 'kb', 'none', 'rid', 0);
  END IF;
  IF act = 'place_remove' THEN
    v_id := f_place_find(p_user, nm);
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('text', 'Não achei o local "' || nm || '". Veja com /contatos.', 'kb', 'none', 'rid', 0);
    END IF;
    DELETE FROM places WHERE id = v_id AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Tirei o local ' || nm || ' da sua lista.', 'kb', 'none', 'rid', 0);
  END IF;
  -- place_save
  IF ad = '' THEN
    RETURN jsonb_build_object('text', 'Qual o endereço de "' || nm || '"? Ex.: "o local ' || nm || ' é Rua das Flores, 120".', 'kb', 'none', 'rid', 0);
  END IF;
  INSERT INTO places (user_id, name, norm_name, address)
  VALUES (p_user, lower(left(nm, 60)), f_norm(left(nm, 60)), left(ad, 200))
  ON CONFLICT (user_id, norm_name) DO UPDATE SET address = EXCLUDED.address;
  RETURN jsonb_build_object('text', 'Salvei o local ' || lower(left(nm, 60)) || ': ' || left(ad, 200) || '. Quando você marcar algo na ' || lower(left(nm, 60)) || ', eu uso esse endereço.', 'kb', 'none', 'rid', 0);
END $$;

-- ---------- f_contacts passa a aceitar place_save / place_list / place_remove ----------
DO $$
BEGIN
  IF to_regproc('agente.f_contacts_base') IS NULL THEN
    ALTER FUNCTION agente.f_contacts(bigint, jsonb) RENAME TO f_contacts_base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION f_contacts(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE act text := lower(coalesce(p->>'contact_action', ''));
BEGIN
  IF act IN ('place_save', 'place_list', 'place_remove') THEN
    RETURN f_places(p_user, jsonb_build_object('act', act, 'name', coalesce(p->>'contact_name', ''), 'address', coalesce(p->>'place_address', '')));
  END IF;
  RETURN f_contacts_base(p_user, p);
END $$;

-- ---------- locais e grupos para o prompt da IA (uma linha cada) ----------
CREATE OR REPLACE FUNCTION f_ai_places(p_user bigint) RETURNS text
LANGUAGE sql STABLE SET search_path TO 'agente','public' AS $$
  SELECT coalesce(string_agg(name || ' = ' || address, '; ' ORDER BY name), '') FROM places WHERE user_id = p_user;
$$;

CREATE OR REPLACE FUNCTION f_ai_groups(p_user bigint) RETURNS text
LANGUAGE sql STABLE SET search_path TO 'agente','public' AS $$
  SELECT coalesce(string_agg(name, ', ' ORDER BY name), '') FROM contact_groups WHERE user_id = p_user;
$$;

-- ---------- /contatos e /config ----------
CREATE OR REPLACE FUNCTION f_command_data(p_user bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE
  u users%ROWTYPE; r record; t text := ''; c text; g text; l text;
  nc integer; ng integer; np integer;
  lead text; ev text; cfg text;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('contatos', 'Não achei o seu cadastro.', 'config', 'Não achei o seu cadastro.'); END IF;
  SELECT count(*) INTO nc FROM contacts WHERE user_id = p_user;
  SELECT count(*) INTO ng FROM contact_groups WHERE user_id = p_user;
  SELECT count(*) INTO np FROM places WHERE user_id = p_user;

  -- /contatos
  c := 'Contatos (' || nc || '):';
  IF nc = 0 THEN c := c || E'\n- nenhum ainda. Ex.: "salva o e-mail da Claudia: claudia@x.com"'; END IF;
  FOR r IN SELECT name, email, favorite FROM contacts WHERE user_id = p_user ORDER BY favorite DESC, name LOOP
    c := c || E'\n- ' || f_ct_disp(r.name) || CASE WHEN r.favorite THEN ' (favorito)' ELSE '' END || ' - ' || r.email;
  END LOOP;
  g := 'Grupos (' || ng || '):';
  IF ng = 0 THEN g := g || E'\n- nenhum ainda. Ex.: "cria o grupo família com Ana e Bia"'; END IF;
  FOR r IN SELECT cg.name, (SELECT string_agg(f_ct_disp(ct.name), ', ' ORDER BY ct.name)
                              FROM contact_group_members m JOIN contacts ct ON ct.id = m.contact_id WHERE m.group_id = cg.id) AS membros
             FROM contact_groups cg WHERE cg.user_id = p_user ORDER BY cg.name LOOP
    g := g || E'\n- ' || f_ct_disp(r.name) || ': ' || coalesce(r.membros, 'sem ninguém');
  END LOOP;
  l := 'Locais salvos (' || np || '):';
  IF np = 0 THEN l := l || E'\n- nenhum ainda. Ex.: "o local igreja é Rua das Flores, 120"'; END IF;
  FOR r IN SELECT name, address FROM places WHERE user_id = p_user ORDER BY name LOOP
    l := l || E'\n- ' || f_ct_disp(r.name) || ': ' || r.address;
  END LOOP;
  t := c || E'\n\n' || g || E'\n\n' || l
    || E'\n\nPara marcar com eles: "festa da igreja na sexta com a família" (uso o local e o grupo salvos, pergunto só a hora e confirmo antes de enviar o convite).'
    || E'\nPara mexer: "tira a Claudia dos contatos", "apaga o grupo família", "tira o local igreja".';

  -- /config
  lead := CASE WHEN u.default_lead_minutes IS NULL THEN 'pergunto a cada vez'
               WHEN u.default_lead_minutes = 0 THEN 'nunca avisar antes'
               ELSE u.default_lead_minutes || ' min antes' END;
  ev := CASE WHEN u.evening_enabled THEN to_char(u.evening_time, 'HH24:MI') ELSE 'desligado' END;
  cfg := 'Suas preferências:'
    || E'\n- Como te chamo: ' || coalesce(nullif(u.nickname, ''), u.name)
    || E'\n- Resumo da manhã: ' || coalesce(to_char(u.summary_time, 'HH24:MI'), 'desligado')
    || E'\n- Resumo do fim do dia: ' || ev
    || E'\n- Aviso antes dos compromissos: ' || lead
    || E'\n- Aviso de estoque: ' || u.supply_alert_days || ' dias antes de acabar (remédio: 7 dias)'
    || E'\n- Fechamento do mês financeiro: dia ' || u.fin_closing_day
    || E'\n- Fuso horário: ' || u.timezone
    || E'\n- Emojis: ' || CASE WHEN u.no_emoji THEN 'desligados' ELSE 'ligados' END
    || E'\n- Google Agenda e Tarefas: ' || CASE WHEN coalesce(u.calendar_key, '') <> '' THEN 'conectados' ELSE 'não conectados' END
    || E'\n\nGuardado por mim: ' || nc || ' contatos, ' || ng || ' grupos, ' || np || ' locais, '
    || (SELECT count(*) FROM lists WHERE user_id = p_user) || ' listas, '
    || (SELECT count(*) FROM notes WHERE user_id = p_user) || ' notas, '
    || (SELECT count(*) FROM projects WHERE user_id = p_user) || ' projetos e '
    || (SELECT count(*) FROM documents WHERE user_id = p_user) || ' documentos.'
    || E'\n\nPara mudar, é só me dizer: "resumo às 8h", "desliga o resumo do fim do dia", "sempre me avise 30 min antes", "avise o estoque com 7 dias", "fecha dia 10", "me chama de Dri", "sem emojis". Para ver contatos, grupos e locais: /contatos.';
  RETURN jsonb_build_object('contatos', t, 'config', cfg);
END $$;

-- ---------- f_invite_prepare: usa local salvo, mostra o grupo e orienta quando nao acha ----------
CREATE OR REPLACE FUNCTION f_invite_prepare(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  u users%ROWTYPE;
  names text[] := COALESCE(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'invitees') = 'array' THEN p->'invitees' ELSE '[]'::jsonb END)), '{}');
  v_meet boolean := COALESCE((p->>'meet')::boolean, false);
  v_start timestamptz; v_end timestamptz; v_title text;
  res jsonb; unk text[]; emails text; shown text; ex text; pid bigint; pl jsonb; lbl text; tzn text;
  v_loc text; v_place bigint; gtxt text;
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

  -- local: se o nome bate com um local salvo, usa o endereço salvo
  v_loc := COALESCE(btrim(p->>'location'), '');
  v_place := f_place_find(p_user, v_loc);
  IF v_place IS NOT NULL THEN SELECT address INTO v_loc FROM places WHERE id = v_place; END IF;

  res := f_resolve_invitees(p_user, names);
  unk := COALESCE(ARRAY(SELECT jsonb_array_elements_text(res->'unknown')), '{}');
  IF array_length(unk, 1) > 0 THEN
    RETURN jsonb_build_object('text', 'Não achei ' || (SELECT string_agg('"' || x || '"', ' e ') FROM unnest(unk) x)
      || ' nos seus contatos nem grupos. Para criar um grupo, diga: "cria o grupo ' || unk[1] || ' com Fulano e Beltrana". Ou me passe o e-mail: "o e-mail ' || f_ct_de(unk[1]) || ' é fulano@dominio.com".', 'kb', 'none', 'rid', 0);
  END IF;
  IF array_length(names, 1) > 0 AND jsonb_array_length(res->'invitees') = 0 THEN
    RETURN jsonb_build_object('text', 'Não encontrei ninguém para convidar (o grupo está vazio?). Veja com /contatos.', 'kb', 'none', 'rid', 0);
  END IF;
  -- sem repetir e-mail
  SELECT string_agg(e, ',' ORDER BY o), string_agg(nm, ', ' ORDER BY o)
    INTO emails, shown
  FROM (SELECT DISTINCT ON (x->>'email') x->>'email' AS e,
               CASE WHEN x->>'name' = x->>'email' THEN x->>'email' ELSE f_ct_disp(x->>'name') END AS nm, o
        FROM jsonb_array_elements(res->'invitees') WITH ORDINALITY t(x, o) ORDER BY x->>'email', o) d;
  -- quais nomes citados eram grupos
  SELECT string_agg('grupo ' || f_ct_disp(cg.name), ' e ') INTO gtxt FROM unnest(names) x JOIN contact_groups cg ON cg.id = f_ct_group_find(p_user, x);

  pl := jsonb_build_object('summary', v_title, 'start', f_ct_iso(v_start, tzn),
        'end', f_ct_iso(v_end, tzn),
        'location', v_loc, 'attendees', COALESCE(emails, ''), 'meet', v_meet,
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
  IF v_loc <> '' THEN ex := ex || ' em ' || v_loc; END IF;
  IF shown IS NOT NULL THEN
    ex := ex || ' e enviar convite para ' || shown || CASE WHEN gtxt IS NOT NULL THEN ' (' || gtxt || ')' ELSE '' END;
  END IF;
  IF v_meet THEN ex := ex || ' (com link do Meet)'; END IF;
  RETURN jsonb_build_object('text', ex || '?', 'kb', 'ag_confirm', 'rid', pid);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('text', 'Não consegui preparar o convite agora. Tente de novo em instantes.', 'kb', 'none', 'rid', 0);
END $$;

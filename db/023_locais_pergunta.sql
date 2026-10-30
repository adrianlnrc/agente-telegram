-- Locais salvos: pergunta de endereco quando o local nao e conhecido, e o comando /locais.
-- Idempotente. Depende de 021_locais_comandos.sql (places, f_places, f_command_data, f_invite_prepare),
-- 022_menu.sql (f_menu, cadeia de f_callback) e 014 (agenda_pending, f_resolve_invitees).
SET search_path TO agente, public;

-- ---------- pendencia da pergunta de endereco ----------
CREATE TABLE IF NOT EXISTS place_pending (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  norm_name  text NOT NULL,
  payload    jsonb NOT NULL DEFAULT '{}'::jsonb,
  state      text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'done', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS place_pending_user_state_idx ON place_pending (user_id, state);

-- O texto parece um nome de lugar (e nao um endereco nem um compromisso online)?
-- Sem digitos, ate 40 caracteres, e nao online/zoom/meet/teams/remoto/telefone.
CREATE OR REPLACE FUNCTION f_place_is_name(p_text text) RETURNS boolean
LANGUAGE sql STABLE SET search_path TO 'agente','public' AS $$
  SELECT btrim(coalesce(p_text, '')) <> ''
     AND length(btrim(p_text)) <= 40
     AND btrim(p_text) !~ '[0-9]'
     AND f_norm(p_text) !~ '\y(online|zoom|meet|teams|remoto|telefone)\y';
$$;

-- ---------- f_invite_prepare: pergunta o endereco de local desconhecido ----------
CREATE OR REPLACE FUNCTION f_invite_prepare(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  u users%ROWTYPE;
  names text[] := COALESCE(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'invitees') = 'array' THEN p->'invitees' ELSE '[]'::jsonb END)), '{}');
  v_meet boolean := COALESCE((p->>'meet')::boolean, false);
  v_start timestamptz; v_end timestamptz; v_title text;
  res jsonb; unk text[]; emails text; shown text; ex text; pid bigint; pl jsonb; lbl text; tzn text;
  v_loc text; v_place bigint; gtxt text; v_pname text; v_pnorm text; v_ppid bigint;
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

  -- local que parece nome e nao esta salvo: pergunta o endereco antes de criar a pendencia do compromisso
  IF v_place IS NULL AND COALESCE((p->>'place_checked')::boolean, false) IS NOT TRUE AND f_place_is_name(v_loc) THEN
    v_pname := lower(btrim(regexp_replace(v_loc, '^(a|o|na|no|da|do|de|em) ', '', 'i')));
    v_pnorm := f_norm(left(v_pname, 60));
    IF v_pnorm <> '' THEN
      UPDATE place_pending SET state = 'cancelled'
       WHERE user_id = p_user AND state = 'open' AND (norm_name = v_pnorm OR created_at < now() - interval '30 minutes');
      INSERT INTO place_pending(user_id, name, norm_name, payload) VALUES (p_user, v_pname, v_pnorm, p) RETURNING id INTO v_ppid;
      RETURN jsonb_build_object('text', 'Não tenho o endereço de "' || v_pname || '". Qual é? Eu salvo para as próximas vezes.', 'kb', 'place_ask', 'rid', v_ppid);
    END IF;
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

-- ---------- f_places: depois de salvar, continua o compromisso que esperava o endereco ----------
CREATE OR REPLACE FUNCTION f_places(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE
  act text := lower(coalesce(p->>'act', ''));
  nm text := btrim(regexp_replace(btrim(coalesce(p->>'name', '')), '^(a|o|na|no|da|do|de|em) ', '', 'i'));
  ad text := btrim(coalesce(p->>'address', ''));
  v_id bigint; t text; r record; n integer := 0;
  pp place_pending%ROWTYPE; nx jsonb; saved text;
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
      RETURN jsonb_build_object('text', 'Não achei o local "' || nm || '". Veja com /locais.', 'kb', 'none', 'rid', 0);
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
  saved := 'Salvei o local ' || lower(left(nm, 60)) || ': ' || left(ad, 200) || '.';

  -- ha um compromisso esperando o endereco deste local? continua nele
  SELECT * INTO pp FROM place_pending
   WHERE user_id = p_user AND state = 'open' AND norm_name = f_norm(left(nm, 60)) AND created_at > now() - interval '30 minutes'
   ORDER BY id DESC LIMIT 1;
  IF FOUND THEN
    UPDATE place_pending SET state = 'done' WHERE id = pp.id;
    nx := f_invite_prepare(p_user, pp.payload || jsonb_build_object('place_checked', true));
    RETURN jsonb_build_object('text', saved || E'\n\n' || (nx->>'text'), 'kb', nx->'kb', 'rid', nx->'rid');
  END IF;
  RETURN jsonb_build_object('text', saved || ' Quando você marcar algo na ' || lower(left(nm, 60)) || ', eu uso esse endereço.', 'kb', 'none', 'rid', 0);
END $$;

-- ---------- botoes plskip / plnever ----------
CREATE OR REPLACE FUNCTION f_place_cb(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint; pp place_pending%ROWTYPE; nx jsonb; pre text := '';
BEGIN
  BEGIN v_id := NULLIF(split_part(p_data, ':', 2), '')::bigint; EXCEPTION WHEN OTHERS THEN v_id := NULL; END;
  IF a NOT IN ('plskip', 'plnever') OR v_id IS NULL THEN
    RETURN jsonb_build_object('text', 'Não entendi esse botão.', 'kb', 'none', 'rid', 0);
  END IF;
  SELECT * INTO pp FROM place_pending WHERE id = v_id AND user_id = p_user FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não encontrei essa pergunta.', 'kb', 'none', 'rid', 0); END IF;
  IF pp.state <> 'open' THEN RETURN jsonb_build_object('text', 'Essa pergunta já foi respondida.', 'kb', 'none', 'rid', 0); END IF;
  IF pp.created_at < now() - interval '30 minutes' THEN
    UPDATE place_pending SET state = 'cancelled' WHERE id = v_id;
    RETURN jsonb_build_object('text', 'Essa pergunta expirou. Peça o compromisso de novo.', 'kb', 'none', 'rid', 0);
  END IF;
  UPDATE place_pending SET state = 'done' WHERE id = v_id;
  IF a = 'plnever' THEN
    INSERT INTO places (user_id, name, norm_name, address)
    VALUES (p_user, lower(left(pp.name, 60)), pp.norm_name, left(pp.name, 200))
    ON CONFLICT (user_id, norm_name) DO NOTHING;
    pre := 'Ok, não pergunto mais o endereço de ' || pp.name || E'.\n\n';
  END IF;
  nx := f_invite_prepare(p_user, pp.payload || jsonb_build_object('place_checked', true));
  RETURN jsonb_build_object('text', pre || (nx->>'text'), 'kb', nx->'kb', 'rid', nx->'rid');
END $$;

-- ---------- f_callback: prefixo pl (plskip / plnever) ----------
-- Cadeia: f_callback (este) -> f_callback_pre_places (mn) -> f_callback_pre_menu -> demais.
DO $$
BEGIN
  IF to_regproc('agente.f_callback_pre_places') IS NULL THEN
    ALTER FUNCTION agente.f_callback(bigint, text) RENAME TO f_callback_pre_places;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION f_callback(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
BEGIN
  IF split_part(p_data, ':', 1) IN ('plskip', 'plnever') THEN
    RETURN f_place_cb(p_user, p_data);
  END IF;
  RETURN f_callback_pre_places(p_user, p_data);
END $$;

-- ---------- /locais: f_command_data devolve tambem a chave locais ----------
DO $$
BEGIN
  IF to_regproc('agente.f_command_data_base') IS NULL THEN
    ALTER FUNCTION agente.f_command_data(bigint) RENAME TO f_command_data_base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION f_command_data(p_user bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE r record; l text; np integer;
BEGIN
  SELECT count(*) INTO np FROM places WHERE user_id = p_user;
  l := 'Locais salvos (' || np || '):';
  IF np = 0 THEN l := l || E'\n- nenhum ainda.'; END IF;
  FOR r IN SELECT name, address FROM places WHERE user_id = p_user ORDER BY name LOOP
    l := l || E'\n- ' || f_ct_disp(r.name) || ': ' || CASE WHEN f_norm(r.address) = r.name OR lower(r.address) = lower(r.name) OR f_norm(r.address) = f_norm(r.name) THEN '(sem endereço)' ELSE r.address END;
  END LOOP;
  l := l || E'\n\nOs locais ficam guardados só para você, no meu banco de dados.'
    || E'\nPara salvar: "o local igreja é Rua das Flores, 120".'
    || E'\nPara tirar: "tira o local igreja".'
    || E'\nQuando você marcar algo num lugar que eu não conheço (por exemplo "na igreja"), eu pergunto o endereço e salvo para as próximas vezes.'
    || E'\n\n/contatos mostra também contatos e grupos.';
  RETURN f_command_data_base(p_user) || jsonb_build_object('locais', l);
END $$;

-- ---------- texto do menu (area Contatos e locais cita /locais e a pergunta de endereco) ----------
CREATE OR REPLACE FUNCTION f_menu(p_user bigint, p_key text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE k text := lower(coalesce(btrim(p_key), 'inicio')); t text;
BEGIN
  t := CASE k
  WHEN 'lembretes' THEN
    E'Lembretes e avisos\nEu aviso na hora e você escolhe: Feito, Adiar 1h ou Adiar amanhã.\n\nTente dizer:\n- "me lembre amanhã às 9h de passar na farmácia"\n- "toda sexta às 18h me lembre de pagar a diarista"\n- "lembra nos dois de comprar pão às 18h" (aviso para você e para a outra pessoa)\n- "sempre me avise 30 min antes dos compromissos"\n- "para de me lembrar da vitamina D"'
  WHEN 'agenda' THEN
    E'Agenda (Google Agenda)\nCrio, mostro, movo e cancelo compromissos. Convites que você receber chegam aqui com Aceitar e Recusar.\n\nTente dizer:\n- "o que tenho hoje?" ou "o que tenho essa semana?"\n- "reunião sexta às 10h, me lembre 1h antes"\n- "move a reunião de sexta para 15h"\n- "cancela a reunião de amanhã"\n- "quando estou livre quinta à tarde?"\n\nMudanças e cancelamentos pedem confirmação por botão.'
  WHEN 'tarefas' THEN
    E'Tarefas (Google Tasks)\nAfazeres soltos, sem hora marcada.\n\nTente dizer:\n- "anota na lista: ligar pro contador"\n- "o que tenho nas tarefas?"\n- "conclui a tarefa do contador"\n- "o que eu concluí essa semana?"\n\nPara guardar uma ideia ou um texto livre, use as Notas: "anota a ideia ...".'
  WHEN 'remedios' THEN
    E'Remédios e estoque\nControlo quanto resta, aviso na hora de tomar e quando está acabando.\n\nTente dizer:\n- "me lembre de tomar losartana todo dia às 8h" (repito a cada 10 min até você tocar Tomei)\n- "tomei a vitamina D"\n- "comprei a vitamina D"\n- "tenho 12 na cartela"\n\nPode mandar a foto da cartela: eu leio o nome e quantos comprimidos restam. O aviso de compra vem no resumo da manhã.'
  WHEN 'dinheiro' THEN
    E'Dinheiro\nRegistro gastos e receitas e mostro para onde o dinheiro foi.\n\nTente dizer:\n- "gastei 42 no mercado" (texto, áudio, foto ou PDF do recibo)\n- "tênis 600 em 3x" ou "aluguel 1500 todo dia 5"\n- "quanto gastei esse mês?" ou "compara com o mês passado"\n- "orçamento de mercado 800" (aviso em 80% e 100%)\n- "o que tenho a pagar?" e "já paguei o aluguel"\n- "o João me deve 50"\n\nO botão Desfazer apaga o último lançamento. "Fecha dia 10" muda o dia de fechamento do mês.'
  WHEN 'pessoas' THEN
    E'Contatos, grupos e locais\nGuardo e-mails, grupos e endereços para marcar compromissos com um pedido só. Os locais ficam guardados só para você, no meu banco de dados.\n\nTente dizer:\n- "salva o e-mail da Cláudia: claudia@x.com"\n- "cria o grupo família com Ana e Bia"\n- "o local igreja é Rua das Flores, 120"\n- "festa da igreja na sexta com a família" (uso o endereço e o grupo salvos, pergunto só a hora e confirmo antes de enviar o convite)\n\nSe você marcar algo num lugar que eu não conheço (por exemplo "na igreja"), eu pergunto o endereço e salvo para as próximas vezes.\n\n/contatos mostra contatos, grupos e locais. /locais mostra só os locais, e como salvar e tirar.'
  WHEN 'docs' THEN
    E'Documentos\nGuardo seus arquivos por pasta e devolvo quando você pedir. Eu guardo só o identificador do arquivo no Telegram, não o conteúdo. Até 50 MB cada.\n\nTente:\n- mandar a foto ou o PDF e dizer "guarda na pasta Casa"\n- "acha a apólice"\n- "me manda tudo da pasta Reforma"\n- "me avisa antes do alvará vencer em 20/12"'
  WHEN 'listas' THEN
    E'Listas e notas\nListas para marcar e notas de texto livre para achar depois.\n\nTente dizer:\n- "lista de mercado: arroz, café e detergente"\n- "marca o arroz" ou "comprei o café"\n- "me mostra a lista de mercado"\n- "anota a ideia da assinatura anual"\n- "o que eu anotei sobre a expansão?"\n- "minhas últimas notas"\n\nApagar ou esvaziar pede confirmação.'
  WHEN 'projetos' THEN
    E'Projetos\nTrabalhos maiores, com prazo e várias tarefas.\n\nTente dizer:\n- "novo projeto Reforma, prazo 30/11"\n- "adiciona as tarefas pintar sala e trocar piso"\n- "quebra o projeto em tarefas" (eu sugiro e você confirma)\n- "marca contratar pintor como feito"\n- "como está a reforma?"\n- "o que está atrasado?"\n\nProjetos com prazo perto aparecem no resumo da manhã.'
  WHEN 'resumos' THEN
    E'Resumos\nManhã (padrão 07:30): compromissos, tarefas, lembretes, contas, estoque e projetos. Fim do dia (20:00): o que ficou pendente e o que vem amanhã.\n\nTente dizer:\n- "resumo às 8h"\n- "desliga o resumo do fim do dia"'
  WHEN 'ajustes' THEN
    E'Ajustes\n/config mostra suas preferências. Para mudar, é só pedir:\n- "me chama de Dri"\n- "sem emojis"\n- "sempre me avise 30 min antes"\n- "avise o estoque com 7 dias"\n- "fecha dia 10"'
  WHEN 'entrada' THEN
    E'Voz, foto e PDF\nPode falar comigo como falaria com uma pessoa.\n\n- Áudio: eu transcrevo e faço o pedido.\n- Foto ou PDF de recibo, nota ou boleto: eu leio e lanço o gasto para você confirmar.\n- Foto da cartela de remédio: eu leio o nome e a quantidade.\n- Quando eu perguntar algo ("Que horas?"), responda numa mensagem só, como "às 19h".'
  ELSE
    E'O que eu faço\nToque numa área para ver o que dá para pedir, com exemplos. Você pode falar do jeito que fala no dia a dia, por texto ou áudio.'
  END;
  RETURN jsonb_build_object('text', t, 'kb', 'menu', 'rid', 0);
END $$;


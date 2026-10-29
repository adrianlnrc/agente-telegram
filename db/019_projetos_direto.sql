-- Fase 4: tarefas que o usuario listou entram direto; so a sugestao da IA (quebra o projeto) pede confirmacao.
-- A IA marca task_name='lista_do_usuario' (regra do prompt em agente:cfg:rules).
CREATE OR REPLACE FUNCTION agente.f_projects(p_user bigint, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'agente', 'public'
AS $function$
DECLARE
  act text := coalesce(p->>'action', '');
  nm text := btrim(coalesce(p->>'name', ''));
  today date := f_fin_today(p_user);
  v_due date; due_bad boolean := false;
  res jsonb; pid bigint; pname text; tres jsonb; tid bigint;
  tl jsonb := '[]'::jsonb; e text; parts text[]; td date; ttl text; k integer;
  t text; r record; n integer; m integer; dleft integer; v_pend bigint; v_urg boolean;
BEGIN
  IF p_user IS NULL OR NOT EXISTS (SELECT 1 FROM users WHERE id = p_user) THEN
    RETURN jsonb_build_object('text', 'Não encontrei o seu cadastro.', 'kb', 'none', 'rid', 0);
  END IF;
  BEGIN v_due := nullif(p->>'due', '')::date; EXCEPTION WHEN others THEN v_due := NULL; due_bad := true; END;

  -- lista de tarefas propostas
  IF jsonb_typeof(p->'tasks') = 'array' THEN
    FOR e IN SELECT jsonb_array_elements_text(p->'tasks') LOOP
      e := btrim(e);
      IF e = '' THEN CONTINUE; END IF;
      parts := regexp_split_to_array(e, '[|]');
      ttl := btrim(parts[1]);
      IF ttl = '' THEN CONTINUE; END IF;
      td := NULL;
      IF array_length(parts, 1) > 1 THEN
        BEGIN td := nullif(btrim(parts[2]), '')::date; EXCEPTION WHEN others THEN td := NULL; END;
        IF td < today THEN td := NULL; END IF;
      END IF;
      IF jsonb_array_length(tl) < 40 THEN
        tl := tl || jsonb_build_array(jsonb_build_object('title', left(ttl, 200), 'due', td));
      END IF;
    END LOOP;
  END IF;

  -- ---------- listar
  IF act = 'list' THEN
    n := 0; t := '';
    FOR r IN
      SELECT pr.id, pr.name, pr.due_date,
             (SELECT count(*) FROM project_tasks x WHERE x.project_id = pr.id) AS tot,
             (SELECT count(*) FROM project_tasks x WHERE x.project_id = pr.id AND x.done) AS dn,
             (SELECT count(*) FROM project_tasks x WHERE x.project_id = pr.id AND NOT x.done AND x.due_date < today) AS late
        FROM projects pr WHERE pr.user_id = p_user ORDER BY pr.due_date NULLS LAST, pr.created_at
    LOOP
      n := n + 1;
      t := t || E'\n' || n || '. ' || r.name || ' - ' || CASE WHEN r.tot = 0 THEN 'sem tarefas' ELSE r.dn || '/' || r.tot END
           || CASE WHEN r.due_date IS NOT NULL THEN ', prazo ' || f_proj_fmt(r.due_date, today) ELSE '' END
           || CASE WHEN r.late > 0 THEN ', ' || r.late || ' atrasada' || CASE WHEN r.late > 1 THEN 's' ELSE '' END ELSE '' END;
    END LOOP;
    IF n = 0 THEN RETURN jsonb_build_object('text', 'Você ainda não tem projetos. Ex.: "novo projeto: mudança do escritório, prazo 30/09".', 'kb', 'none', 'rid', 0); END IF;
    RETURN jsonb_build_object('text', 'Seus projetos:' || t, 'kb', 'none', 'rid', 0);
  END IF;

  -- ---------- atrasadas (um projeto ou todos)
  IF act = 'overdue' THEN
    IF nm <> '' THEN
      res := f_proj_resolve(p_user, nm);
      IF res ? 'err' THEN RETURN jsonb_build_object('text', res->>'err', 'kb', 'none', 'rid', 0); END IF;
      pid := (res->>'id')::bigint; pname := res->>'name';
      t := f_proj_overdue_text(p_user, pid, today);
      RETURN jsonb_build_object('text', CASE WHEN t = '' THEN 'Nada atrasado no projeto ' || pname || '.' ELSE 'Atrasado no projeto ' || pname || ':' || t END, 'kb', 'none', 'rid', 0);
    END IF;
    t := f_proj_overdue_text(p_user, NULL, today);
    IF t = '' THEN RETURN jsonb_build_object('text', 'Nenhuma tarefa de projeto está atrasada.', 'kb', 'none', 'rid', 0); END IF;
    RETURN jsonb_build_object('text', 'Tarefas atrasadas:' || t, 'kb', 'none', 'rid', 0);
  END IF;

  -- ---------- criar
  IF act = 'create' THEN
    IF nm = '' THEN RETURN jsonb_build_object('text', 'Qual o nome do projeto? Ex.: "novo projeto: mudança do escritório, prazo 30/09".', 'kb', 'none', 'rid', 0); END IF;
    IF due_bad OR (v_due IS NOT NULL AND v_due < today) THEN
      RETURN jsonb_build_object('text', 'Esse prazo já passou (hoje é ' || to_char(today, 'DD/MM/YYYY') || '). Qual o prazo do projeto "' || nm || '"?', 'kb', 'none', 'rid', 0);
    END IF;
    IF (SELECT count(*) FROM projects WHERE user_id = p_user) >= 100 THEN
      RETURN jsonb_build_object('text', 'Você já tem muitos projetos (100). Apague algum antes de criar outro.', 'kb', 'none', 'rid', 0);
    END IF;
    INSERT INTO projects (user_id, name, norm_name, due_date) VALUES (p_user, left(nm, 120), f_norm(left(nm, 120)), v_due)
    ON CONFLICT (user_id, norm_name) DO NOTHING RETURNING id INTO pid;
    IF pid IS NULL THEN
      RETURN jsonb_build_object('text', 'Você já tem um projeto chamado "' || nm || '".', 'kb', 'none', 'rid', 0);
    END IF;
    t := 'Projeto criado: ' || left(nm, 120) || CASE WHEN v_due IS NOT NULL THEN ' (prazo ' || to_char(v_due, 'DD/MM/YYYY') || ')' ELSE '' END || '.';
    IF jsonb_array_length(tl) > 0 THEN
      INSERT INTO project_pending (user_id, project_id, tasks) VALUES (p_user, pid, tl) RETURNING id INTO v_pend;
      t := t || E'\n\nPosso gravar estas ' || jsonb_array_length(tl) || ' tarefas?';
      n := 0;
      FOR r IN SELECT x->>'title' AS title, x->>'due' AS due FROM jsonb_array_elements(tl) x LOOP
        n := n + 1;
        t := t || E'\n' || n || '. ' || r.title || CASE WHEN r.due IS NOT NULL THEN ' (até ' || f_proj_fmt(r.due::date, today) || ')' ELSE '' END;
      END LOOP;
      RETURN jsonb_build_object('text', t, 'kb', 'pj_tasks', 'rid', v_pend);
    END IF;
    RETURN jsonb_build_object('text', t || E'\nQuer que eu quebre em tarefas? Diga, por exemplo: "quebra o projeto em tarefas".', 'kb', 'none', 'rid', pid);
  END IF;

  -- demais acoes precisam de um projeto (ou de uma tarefa achada em qualquer projeto)
  IF act = 'complete_task' OR act = 'reopen_task' OR act = 'set_urgent' OR (act = 'set_due' AND btrim(coalesce(p->>'task', '')) <> '') THEN
    IF nm <> '' THEN
      res := f_proj_resolve(p_user, nm);
      IF res ? 'err' THEN RETURN jsonb_build_object('text', res->>'err', 'kb', 'none', 'rid', 0); END IF;
      pid := (res->>'id')::bigint;
    END IF;
    tres := f_proj_task_resolve(p_user, pid, coalesce(nullif(p->>'task', ''), nullif(p->>'title', '')),
                                CASE act WHEN 'complete_task' THEN false WHEN 'reopen_task' THEN true ELSE NULL END);
    IF tres ? 'err' THEN RETURN jsonb_build_object('text', tres->>'err', 'kb', 'none', 'rid', 0); END IF;
    tid := (tres->>'id')::bigint; ttl := tres->>'title'; pid := (tres->>'project_id')::bigint;
    SELECT name INTO pname FROM projects WHERE id = pid AND user_id = p_user;

    IF act = 'complete_task' THEN
      UPDATE project_tasks SET done = true, done_at = now() WHERE id = tid AND user_id = p_user;
      SELECT count(*) INTO n FROM project_tasks WHERE project_id = pid AND user_id = p_user AND NOT done;
      RETURN jsonb_build_object('text', 'Tarefa concluída: ' || ttl || '. Projeto ' || pname || ': ' || f_proj_progress(p_user, pid) || '.'
        || CASE WHEN n = 0 THEN ' Todas as tarefas do projeto estão concluídas!' ELSE '' END, 'kb', 'none', 'rid', 0);
    ELSIF act = 'reopen_task' THEN
      UPDATE project_tasks SET done = false, done_at = NULL WHERE id = tid AND user_id = p_user;
      RETURN jsonb_build_object('text', 'Reabri a tarefa: ' || ttl || '. Projeto ' || pname || ': ' || f_proj_progress(p_user, pid) || '.', 'kb', 'none', 'rid', 0);
    ELSIF act = 'set_urgent' THEN
      v_urg := coalesce((p->>'urgent')::boolean, true);
      UPDATE project_tasks SET urgent = v_urg WHERE id = tid AND user_id = p_user;
      RETURN jsonb_build_object('text', CASE WHEN v_urg THEN 'Marquei como urgente: ' || ttl || ' (projeto ' || pname || ').' ELSE 'Tirei a urgência de: ' || ttl || '.' END, 'kb', 'none', 'rid', 0);
    ELSE -- set_due da tarefa
      IF v_due IS NULL OR due_bad OR v_due < today THEN
        RETURN jsonb_build_object('text', 'Para qual data eu mudo o prazo da tarefa "' || ttl || '"? (hoje é ' || to_char(today, 'DD/MM/YYYY') || ')', 'kb', 'none', 'rid', 0);
      END IF;
      UPDATE project_tasks SET due_date = v_due WHERE id = tid AND user_id = p_user;
      RETURN jsonb_build_object('text', 'Prazo da tarefa "' || ttl || '" agora é ' || to_char(v_due, 'DD/MM/YYYY') || '.', 'kb', 'none', 'rid', 0);
    END IF;
  END IF;

  res := f_proj_resolve(p_user, nm);
  IF res ? 'err' THEN RETURN jsonb_build_object('text', res->>'err', 'kb', 'none', 'rid', 0); END IF;
  pid := (res->>'id')::bigint; pname := res->>'name';

  -- ---------- adicionar tarefas (uma: direto; varias ou quebra: confirma por botao)
  IF act = 'add_tasks' THEN
    IF jsonb_array_length(tl) = 0 THEN
      RETURN jsonb_build_object('text', 'Quais tarefas eu coloco no projeto ' || pname || '? Diga o nome delas, ou peça "quebra o projeto em tarefas".', 'kb', 'none', 'rid', 0);
    END IF;
    IF jsonb_array_length(tl) = 1 THEN
      IF due_bad OR (v_due IS NOT NULL AND v_due < today) THEN
        RETURN jsonb_build_object('text', 'Esse prazo já passou (hoje é ' || to_char(today, 'DD/MM/YYYY') || '). Qual o prazo da tarefa?', 'kb', 'none', 'rid', 0);
      END IF;
      IF v_due IS NOT NULL AND (tl->0->>'due') IS NULL THEN tl := jsonb_build_array(jsonb_set(tl->0, '{due}', to_jsonb(v_due::text))); END IF;
      ttl := tl->0->>'title';
      IF EXISTS (SELECT 1 FROM project_tasks WHERE project_id = pid AND user_id = p_user AND norm_title = f_norm(left(ttl, 200))) THEN
        RETURN jsonb_build_object('text', 'A tarefa "' || ttl || '" já está no projeto ' || pname || '.', 'kb', 'none', 'rid', 0);
      END IF;
      PERFORM f_proj_insert_tasks(p_user, pid, tl);
      RETURN jsonb_build_object('text', 'Tarefa adicionada ao projeto ' || pname || ': ' || ttl
        || CASE WHEN tl->0->>'due' IS NOT NULL THEN ' (até ' || to_char((tl->0->>'due')::date, 'DD/MM/YYYY') || ')' ELSE '' END
        || '. Progresso: ' || f_proj_progress(p_user, pid) || '.', 'kb', 'none', 'rid', 0);
    END IF;
    IF coalesce(p->>'task', '') = 'lista_do_usuario' THEN
      PERFORM f_proj_insert_tasks(p_user, pid, tl);
      t := 'Adicionei ' || jsonb_array_length(tl) || ' tarefas ao projeto ' || pname || ':';
      FOR r IN SELECT x->>'title' AS title FROM jsonb_array_elements(tl) x LOOP
        t := t || E'\n- ' || r.title;
      END LOOP;
      RETURN jsonb_build_object('text', t || E'\nProgresso: ' || f_proj_progress(p_user, pid) || '.', 'kb', 'none', 'rid', 0);
    END IF;
    INSERT INTO project_pending (user_id, project_id, tasks) VALUES (p_user, pid, tl) RETURNING id INTO v_pend;
    t := 'Posso gravar estas ' || jsonb_array_length(tl) || ' tarefas no projeto ' || pname || '?';
    n := 0;
    FOR r IN SELECT x->>'title' AS title, x->>'due' AS due FROM jsonb_array_elements(tl) x LOOP
      n := n + 1;
      t := t || E'\n' || n || '. ' || r.title || CASE WHEN r.due IS NOT NULL THEN ' (até ' || f_proj_fmt(r.due::date, today) || ')' ELSE '' END;
    END LOOP;
    RETURN jsonb_build_object('text', t, 'kb', 'pj_tasks', 'rid', v_pend);
  END IF;

  -- ---------- prazo do projeto
  IF act = 'set_due' THEN
    IF v_due IS NULL OR due_bad OR v_due < today THEN
      RETURN jsonb_build_object('text', 'Para qual data eu mudo o prazo do projeto ' || pname || '? (hoje é ' || to_char(today, 'DD/MM/YYYY') || ')', 'kb', 'none', 'rid', 0);
    END IF;
    UPDATE projects SET due_date = v_due WHERE id = pid AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Prazo do projeto ' || pname || ' agora é ' || to_char(v_due, 'DD/MM/YYYY') || '.', 'kb', 'none', 'rid', 0);
  END IF;

  -- ---------- renomear (name = nome atual, title = nome novo)
  IF act = 'rename' THEN
    ttl := btrim(coalesce(p->>'title', ''));
    IF ttl = '' THEN RETURN jsonb_build_object('text', 'Qual o novo nome do projeto ' || pname || '?', 'kb', 'none', 'rid', 0); END IF;
    IF EXISTS (SELECT 1 FROM projects WHERE user_id = p_user AND norm_name = f_norm(left(ttl, 120)) AND id <> pid) THEN
      RETURN jsonb_build_object('text', 'Você já tem outro projeto chamado "' || ttl || '".', 'kb', 'none', 'rid', 0);
    END IF;
    UPDATE projects SET name = left(ttl, 120), norm_name = f_norm(left(ttl, 120)) WHERE id = pid AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Renomeei o projeto ' || pname || ' para ' || left(ttl, 120) || '.', 'kb', 'none', 'rid', 0);
  END IF;

  -- ---------- apagar (confirmacao por botao)
  IF act = 'delete' THEN
    SELECT count(*) INTO n FROM project_tasks WHERE project_id = pid AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Apagar o projeto ' || pname || CASE WHEN n > 0 THEN ' e as ' || n || ' tarefa' || CASE WHEN n > 1 THEN 's' ELSE '' END || ' dele' ELSE '' END || '? Isso não dá para desfazer.', 'kb', 'pj_del', 'rid', pid);
  END IF;

  -- ---------- mostrar um projeto
  IF act = 'show' THEN
    SELECT due_date INTO v_due FROM projects WHERE id = pid AND user_id = p_user;
    t := 'Projeto ' || pname;
    IF v_due IS NOT NULL THEN
      dleft := v_due - today;
      t := t || E'\nPrazo: ' || to_char(v_due, 'DD/MM/YYYY') || CASE WHEN dleft > 1 THEN ' (faltam ' || dleft || ' dias)' WHEN dleft = 1 THEN ' (amanhã)' WHEN dleft = 0 THEN ' (hoje)' WHEN dleft = -1 THEN ' (venceu ontem)' ELSE ' (venceu há ' || (-dleft) || ' dias)' END;
    END IF;
    t := t || E'\nProgresso: ' || f_proj_progress(p_user, pid);
    e := f_proj_overdue_text(p_user, pid, today, 8);
    IF e <> '' THEN t := t || E'\n\nAtrasadas:' || e; END IF;
    n := 0; e := '';
    FOR r IN
      SELECT title, due_date, urgent FROM project_tasks WHERE project_id = pid AND user_id = p_user AND NOT done AND (due_date IS NULL OR due_date >= today)
       ORDER BY urgent DESC, due_date NULLS LAST, id LIMIT 6
    LOOP
      n := n + 1;
      e := e || E'\n- ' || r.title || CASE WHEN r.due_date IS NOT NULL THEN ' (até ' || f_proj_fmt(r.due_date, today) || ')' ELSE '' END || CASE WHEN r.urgent THEN ' [urgente]' ELSE '' END;
    END LOOP;
    IF e <> '' THEN
      SELECT count(*) INTO m FROM project_tasks WHERE project_id = pid AND user_id = p_user AND NOT done AND (due_date IS NULL OR due_date >= today);
      t := t || E'\n\nPróximas:' || e || CASE WHEN m > n THEN E'\n... e mais ' || (m - n) ELSE '' END;
    ELSIF NOT EXISTS (SELECT 1 FROM project_tasks WHERE project_id = pid AND user_id = p_user) THEN
      t := t || E'\n\nAinda sem tarefas. Diga "quebra o projeto em tarefas" ou "adiciona a tarefa X ao projeto".';
    ELSIF e = '' AND f_proj_overdue_text(p_user, pid, today, 1) = '' THEN
      t := t || E'\n\nTodas as tarefas estão concluídas.';
    END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'none', 'rid', 0);
  END IF;

  RETURN jsonb_build_object('text', 'Não entendi o que fazer com o projeto. Ex.: "como está o projeto do site?" ou "meus projetos".', 'kb', 'none', 'rid', 0);
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_projects: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui mexer nos projetos agora. Tente de novo.', 'kb', 'none', 'rid', 0);
END $function$;

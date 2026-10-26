-- Fase 4 / Modulo P: projetos com tarefas proprias no banco (NAO e o Google Tasks).
-- Idempotente (CREATE OR REPLACE / IF NOT EXISTS). Dono de: projects, project_tasks, project_pending,
-- f_projects, f_projects_cb, f_projects_summary (+ auxiliares f_proj_*).
-- Callbacks: pjok:<pending> / pjno:<pending> (gravar ou descartar tarefas) e pjdel:<projeto> / pjkeep:<projeto> (apagar projeto).
-- Teclados no n8n: pj_tasks (pjok/pjno) e pj_del (pjdel/pjkeep). Isolamento por user_id em toda consulta.
SET search_path TO agente, public;

CREATE TABLE IF NOT EXISTS projects (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  norm_name  text NOT NULL,
  due_date   date,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, norm_name)
);

CREATE TABLE IF NOT EXISTS project_tasks (
  id         bigserial PRIMARY KEY,
  project_id bigint NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title      text NOT NULL,
  norm_title text NOT NULL,
  due_date   date,
  urgent     boolean NOT NULL DEFAULT false,
  done       boolean NOT NULL DEFAULT false,
  done_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, norm_title)
);
CREATE INDEX IF NOT EXISTS project_tasks_user_open ON project_tasks (user_id, due_date) WHERE NOT done;

-- tarefas propostas (quebra do projeto) aguardando o botao de confirmacao
CREATE TABLE IF NOT EXISTS project_pending (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  project_id bigint NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  tasks      jsonb NOT NULL,              -- [{"title":"..","due":"YYYY-MM-DD"|null}]
  state      text NOT NULL DEFAULT 'open' CHECK (state IN ('open','done','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- data curta: DD/MM (com ano se for de outro ano)
CREATE OR REPLACE FUNCTION f_proj_fmt(p_d date, p_today date) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente','public' AS $$
  SELECT CASE WHEN p_d IS NULL THEN '' WHEN extract(year FROM p_d) = extract(year FROM p_today) THEN to_char(p_d, 'DD/MM') ELSE to_char(p_d, 'DD/MM/YYYY') END
$$;

-- ---------- progresso "x/y tarefas (NN%)"
CREATE OR REPLACE FUNCTION f_proj_progress(p_user bigint, p_pid bigint) RETURNS text
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE d integer; t integer;
BEGIN
  SELECT count(*) FILTER (WHERE done), count(*) INTO d, t FROM project_tasks WHERE user_id = p_user AND project_id = p_pid;
  IF t = 0 THEN RETURN 'sem tarefas ainda'; END IF;
  RETURN d || '/' || t || ' tarefa' || CASE WHEN t > 1 THEN 's' ELSE '' END || ' (' || round(100.0 * d / t) || '%)';
END $$;

-- ---------- acha o projeto pelo nome (ou o unico projeto). devolve {id,name} ou {err}
CREATE OR REPLACE FUNCTION f_proj_resolve(p_user bigint, p_name text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE q text := coalesce(f_norm(p_name), ''); toks text[]; ids bigint[]; n integer; lst text; v_name text;
BEGIN
  SELECT array_agg(t) INTO toks FROM (
    SELECT regexp_replace(x, '[^a-z0-9]', '', 'g') AS t FROM unnest(string_to_array(q, ' ')) x) s
   WHERE t <> '' AND t NOT IN ('o','a','os','as','de','do','da','dos','das','projeto','projetos','no','na','em','pro','pra','para','meu','minha','um','uma');
  IF toks IS NULL THEN
    SELECT array_agg(id ORDER BY created_at) INTO ids FROM projects WHERE user_id = p_user;
    n := coalesce(cardinality(ids), 0);
    IF n = 0 THEN RETURN jsonb_build_object('err', 'Você ainda não tem projetos. Ex.: "novo projeto: mudança do escritório, prazo 30/09".'); END IF;
    IF n = 1 THEN SELECT name INTO v_name FROM projects WHERE id = ids[1]; RETURN jsonb_build_object('id', ids[1], 'name', v_name); END IF;
    SELECT string_agg(name, ', ' ORDER BY created_at) INTO lst FROM projects WHERE user_id = p_user;
    RETURN jsonb_build_object('err', 'Qual projeto? Os seus: ' || lst || '.');
  END IF;
  SELECT id, name INTO n, v_name FROM projects WHERE user_id = p_user AND norm_name = q;
  IF FOUND THEN RETURN jsonb_build_object('id', n, 'name', v_name); END IF;
  SELECT array_agg(id ORDER BY created_at) INTO ids FROM projects
   WHERE user_id = p_user AND (SELECT bool_and(norm_name LIKE '%' || x || '%') FROM unnest(toks) x);
  n := coalesce(cardinality(ids), 0);
  IF n = 1 THEN SELECT name INTO v_name FROM projects WHERE id = ids[1]; RETURN jsonb_build_object('id', ids[1], 'name', v_name); END IF;
  IF n > 1 THEN
    SELECT string_agg(name, ', ' ORDER BY created_at) INTO lst FROM projects WHERE id = ANY(ids);
    RETURN jsonb_build_object('err', 'Achei mais de um projeto parecido: ' || lst || '. Qual deles?');
  END IF;
  SELECT string_agg(name, ', ' ORDER BY created_at) INTO lst FROM projects WHERE user_id = p_user;
  RETURN jsonb_build_object('err', 'Não achei o projeto "' || btrim(p_name) || '".' || CASE WHEN lst IS NULL THEN ' Você ainda não tem projetos.' ELSE ' Os seus: ' || lst || '.' END);
END $$;

-- ---------- acha a tarefa pelo nome (dentro do projeto, se dado). p_done: true=so concluidas, false=so abertas, null=todas.
CREATE OR REPLACE FUNCTION f_proj_task_resolve(p_user bigint, p_pid bigint, p_name text, p_done boolean) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE q text := coalesce(f_norm(p_name), ''); toks text[]; ids bigint[]; n integer; lst text; r record;
BEGIN
  SELECT array_agg(t) INTO toks FROM (
    SELECT regexp_replace(x, '[^a-z0-9]', '', 'g') AS t FROM unnest(string_to_array(q, ' ')) x) s
   WHERE t <> '' AND t NOT IN ('o','a','os','as','de','do','da','dos','das','tarefa','tarefas','no','na','em','pro','pra','para','um','uma');
  IF toks IS NULL THEN RETURN jsonb_build_object('err', 'Qual tarefa? Diga o nome dela.'); END IF;
  SELECT t.id, t.title, t.project_id INTO r FROM project_tasks t
   WHERE t.user_id = p_user AND (p_pid IS NULL OR t.project_id = p_pid) AND (p_done IS NULL OR t.done = p_done) AND t.norm_title = q LIMIT 1;
  IF FOUND THEN RETURN jsonb_build_object('id', r.id, 'title', r.title, 'project_id', r.project_id); END IF;
  SELECT array_agg(t.id ORDER BY t.id) INTO ids FROM project_tasks t
   WHERE t.user_id = p_user AND (p_pid IS NULL OR t.project_id = p_pid) AND (p_done IS NULL OR t.done = p_done)
     AND (SELECT bool_and(t.norm_title LIKE '%' || x || '%') FROM unnest(toks) x);
  n := coalesce(cardinality(ids), 0);
  IF n = 1 THEN
    SELECT t.id, t.title, t.project_id INTO r FROM project_tasks t WHERE t.id = ids[1];
    RETURN jsonb_build_object('id', r.id, 'title', r.title, 'project_id', r.project_id);
  END IF;
  IF n > 1 THEN
    SELECT string_agg(t.title || CASE WHEN p_pid IS NULL THEN ' (' || pr.name || ')' ELSE '' END, '; ' ORDER BY t.id) INTO lst
      FROM (SELECT * FROM project_tasks WHERE id = ANY(ids) ORDER BY id LIMIT 5) t JOIN projects pr ON pr.id = t.project_id;
    RETURN jsonb_build_object('err', 'Achei mais de uma tarefa parecida: ' || lst || '. Qual delas?');
  END IF;
  RETURN jsonb_build_object('err', 'Não achei a tarefa "' || btrim(p_name) || '"' ||
    CASE p_done WHEN false THEN ' entre as tarefas em aberto' WHEN true THEN ' entre as concluídas' ELSE '' END || '.');
END $$;

-- ---------- grava as tarefas (jsonb [{"title","due"}]); ignora repetidas. devolve quantas entraram
CREATE OR REPLACE FUNCTION f_proj_insert_tasks(p_user bigint, p_pid bigint, p_tasks jsonb) RETURNS integer
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE x jsonb; n integer := 0; k integer; d date;
BEGIN
  FOR x IN SELECT * FROM jsonb_array_elements(p_tasks) LOOP
    BEGIN d := nullif(x->>'due', '')::date; EXCEPTION WHEN others THEN d := NULL; END;
    INSERT INTO project_tasks (project_id, user_id, title, norm_title, due_date)
    VALUES (p_pid, p_user, left(btrim(x->>'title'), 200), f_norm(left(btrim(x->>'title'), 200)), d)
    ON CONFLICT (project_id, norm_title) DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT;
    n := n + k;
  END LOOP;
  RETURN n;
END $$;

-- ---------- bloco "atrasadas" de um projeto (ou de todos quando p_pid nulo)
CREATE OR REPLACE FUNCTION f_proj_overdue_text(p_user bigint, p_pid bigint, p_today date, p_limit integer DEFAULT 10) RETURNS text
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE r record; t text := ''; k integer := 0; tot integer;
BEGIN
  SELECT count(*) INTO tot FROM project_tasks WHERE user_id = p_user AND NOT done AND due_date < p_today AND (p_pid IS NULL OR project_id = p_pid);
  FOR r IN
    SELECT t.title, t.due_date, t.urgent, pr.name FROM project_tasks t JOIN projects pr ON pr.id = t.project_id
     WHERE t.user_id = p_user AND NOT t.done AND t.due_date < p_today AND (p_pid IS NULL OR t.project_id = p_pid)
     ORDER BY t.due_date, t.id LIMIT p_limit
  LOOP
    k := k + 1;
    t := t || E'\n- ' || r.title || CASE WHEN p_pid IS NULL THEN ' (' || r.name || ')' ELSE '' END || ' - venceu ' || f_proj_fmt(r.due_date, p_today) || CASE WHEN r.urgent THEN ' [urgente]' ELSE '' END;
  END LOOP;
  IF tot > k THEN t := t || E'\n... e mais ' || (tot - k); END IF;
  RETURN t;
END $$;

-- ============================================================ funcao principal (chamada pelo n8n)
-- p: {action, name, title (novo nome em rename), tasks [texto ou "texto|YYYY-MM-DD"], task, due 'YYYY-MM-DD', urgent bool}
CREATE OR REPLACE FUNCTION f_projects(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
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
END $$;

-- ============================================================ botoes
CREATE OR REPLACE FUNCTION f_projects_cb(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
DECLARE a text := split_part(p_data, ':', 1); v_id bigint; pe project_pending%ROWTYPE; pr projects%ROWTYPE; n integer; ins integer;
BEGIN
  BEGIN v_id := nullif(split_part(p_data, ':', 2), '')::bigint; EXCEPTION WHEN others THEN v_id := NULL; END;
  IF a = 'pjno' THEN
    UPDATE project_pending SET state = 'cancelled' WHERE id = v_id AND user_id = p_user AND state = 'open';
    RETURN jsonb_build_object('text', 'Ok, não gravei as tarefas.', 'kb', 'none');
  END IF;
  IF a = 'pjok' THEN
    SELECT * INTO pe FROM project_pending WHERE id = v_id AND user_id = p_user FOR UPDATE;
    IF NOT FOUND OR pe.state <> 'open' THEN RETURN jsonb_build_object('text', 'Essa lista de tarefas já foi tratada.', 'kb', 'none'); END IF;
    SELECT * INTO pr FROM projects WHERE id = pe.project_id AND user_id = p_user;
    IF NOT FOUND THEN
      UPDATE project_pending SET state = 'cancelled' WHERE id = pe.id;
      RETURN jsonb_build_object('text', 'Esse projeto não existe mais.', 'kb', 'none');
    END IF;
    ins := f_proj_insert_tasks(p_user, pe.project_id, pe.tasks);
    UPDATE project_pending SET state = 'done' WHERE id = pe.id;
    n := jsonb_array_length(pe.tasks);
    RETURN jsonb_build_object('text', 'Gravei ' || ins || ' tarefa' || CASE WHEN ins <> 1 THEN 's' ELSE '' END || ' no projeto ' || pr.name
      || CASE WHEN ins < n THEN ' (' || (n - ins) || ' já existia' || CASE WHEN n - ins > 1 THEN 'm' ELSE '' END || ')' ELSE '' END
      || '. Progresso: ' || f_proj_progress(p_user, pr.id) || '.', 'kb', 'none');
  END IF;
  IF a = 'pjkeep' THEN RETURN jsonb_build_object('text', 'Ok, mantive o projeto.', 'kb', 'none'); END IF;
  IF a = 'pjdel' THEN
    SELECT * INTO pr FROM projects WHERE id = v_id AND user_id = p_user;
    IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Esse projeto já foi apagado.', 'kb', 'none'); END IF;
    DELETE FROM projects WHERE id = pr.id AND user_id = p_user;
    RETURN jsonb_build_object('text', 'Apaguei o projeto ' || pr.name || ' e as tarefas dele.', 'kb', 'none');
  END IF;
  RETURN jsonb_build_object('text', 'Não entendi esse botão.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_projects_cb: %', SQLERRM;
  RETURN jsonb_build_object('text', 'Não consegui agora. Tente de novo.', 'kb', 'none');
END $$;

-- ============================================================ dados para os resumos (manha e fim do dia)
-- {overdue:[{project,task,due,days_late,urgent}], due_today:[{project,task,urgent}], soon:[{project,due,open_tasks}],
--  projects_overdue:[{project,due,open_tasks}], count: n, text: "linhas prontas" ('' se nada)}
CREATE OR REPLACE FUNCTION f_projects_summary(p_user bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE today date := f_fin_today(p_user); ov jsonb; dt jsonb; so jsonb; po jsonb; t text := ''; r record; n integer := 0; tot integer;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object('project', pr.name, 'task', x.title, 'due', x.due_date, 'days_late', today - x.due_date, 'urgent', x.urgent) ORDER BY x.due_date, x.id), '[]'::jsonb)
    INTO ov FROM project_tasks x JOIN projects pr ON pr.id = x.project_id WHERE x.user_id = p_user AND NOT x.done AND x.due_date < today;
  SELECT coalesce(jsonb_agg(jsonb_build_object('project', pr.name, 'task', x.title, 'urgent', x.urgent) ORDER BY x.urgent DESC, x.id), '[]'::jsonb)
    INTO dt FROM project_tasks x JOIN projects pr ON pr.id = x.project_id WHERE x.user_id = p_user AND NOT x.done AND x.due_date = today;
  SELECT coalesce(jsonb_agg(jsonb_build_object('project', s.name, 'due', s.due_date, 'open_tasks', s.o) ORDER BY s.due_date), '[]'::jsonb)
    INTO so FROM (SELECT pr.name, pr.due_date, (SELECT count(*) FROM project_tasks x WHERE x.project_id = pr.id AND NOT x.done) AS o
                    FROM projects pr WHERE pr.user_id = p_user AND pr.due_date BETWEEN today AND today + 7) s WHERE s.o > 0;
  SELECT coalesce(jsonb_agg(jsonb_build_object('project', s.name, 'due', s.due_date, 'open_tasks', s.o) ORDER BY s.due_date), '[]'::jsonb)
    INTO po FROM (SELECT pr.name, pr.due_date, (SELECT count(*) FROM project_tasks x WHERE x.project_id = pr.id AND NOT x.done) AS o
                    FROM projects pr WHERE pr.user_id = p_user AND pr.due_date < today) s WHERE s.o > 0;
  n := jsonb_array_length(ov) + jsonb_array_length(dt) + jsonb_array_length(so) + jsonb_array_length(po);
  IF jsonb_array_length(ov) > 0 THEN
    t := t || 'Tarefas de projeto atrasadas:';
    FOR r IN SELECT x->>'project' AS pj, x->>'task' AS tk, (x->>'due')::date AS d FROM jsonb_array_elements(ov) x LIMIT 5 LOOP
      t := t || E'\n- ' || r.tk || ' (' || r.pj || ', venceu ' || f_proj_fmt(r.d, today) || ')';
    END LOOP;
    IF jsonb_array_length(ov) > 5 THEN t := t || E'\n... e mais ' || (jsonb_array_length(ov) - 5); END IF;
  END IF;
  IF jsonb_array_length(dt) > 0 THEN
    t := t || CASE WHEN t <> '' THEN E'\n' ELSE '' END || 'Tarefas de projeto para hoje:';
    FOR r IN SELECT x->>'project' AS pj, x->>'task' AS tk FROM jsonb_array_elements(dt) x LIMIT 5 LOOP
      t := t || E'\n- ' || r.tk || ' (' || r.pj || ')';
    END LOOP;
    IF jsonb_array_length(dt) > 5 THEN t := t || E'\n... e mais ' || (jsonb_array_length(dt) - 5); END IF;
  END IF;
  IF jsonb_array_length(so) > 0 THEN
    t := t || CASE WHEN t <> '' THEN E'\n' ELSE '' END || 'Projetos com prazo nos próximos 7 dias:';
    FOR r IN SELECT x->>'project' AS pj, (x->>'due')::date AS d, (x->>'open_tasks')::int AS o FROM jsonb_array_elements(so) x LIMIT 5 LOOP
      t := t || E'\n- ' || r.pj || ' (prazo ' || f_proj_fmt(r.d, today) || ', ' || r.o || ' tarefa' || CASE WHEN r.o > 1 THEN 's' ELSE '' END || ' em aberto)';
    END LOOP;
  END IF;
  IF jsonb_array_length(po) > 0 THEN
    t := t || CASE WHEN t <> '' THEN E'\n' ELSE '' END || 'Projetos com prazo vencido e tarefas em aberto:';
    FOR r IN SELECT x->>'project' AS pj, (x->>'due')::date AS d FROM jsonb_array_elements(po) x LIMIT 5 LOOP
      t := t || E'\n- ' || r.pj || ' (prazo era ' || f_proj_fmt(r.d, today) || ')';
    END LOOP;
  END IF;
  RETURN jsonb_build_object('overdue', ov, 'due_today', dt, 'soon', so, 'projects_overdue', po, 'count', n, 'text', t);
EXCEPTION WHEN others THEN
  RAISE WARNING 'f_projects_summary: %', SQLERRM;
  RETURN jsonb_build_object('overdue', '[]'::jsonb, 'due_today', '[]'::jsonb, 'soon', '[]'::jsonb, 'projects_overdue', '[]'::jsonb, 'count', 0, 'text', '');
END $$;

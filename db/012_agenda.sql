-- Gestao de agenda (fase 2): mover/cancelar, conflito, horario livre, recorrentes, lembrete ligado a compromisso,
-- promover lembrete a compromisso, convites recebidos e expediente. Depende de 012_base_agenda.sql (agenda_pending, f_callback).
-- Idempotente: CREATE OR REPLACE / IF NOT EXISTS.
SET search_path TO agente, public;

-- ---------------------------------------------------------------- tabelas e colunas
ALTER TABLE users ADD COLUMN IF NOT EXISTS work_start time NOT NULL DEFAULT '08:00';
ALTER TABLE users ADD COLUMN IF NOT EXISTS work_end   time NOT NULL DEFAULT '19:00';

-- Espelho local dos compromissos recorrentes criados pelo bot (para achar a proxima ocorrencia).
CREATE TABLE IF NOT EXISTS agenda_series (
  id                bigserial PRIMARY KEY,
  user_id           bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title             text NOT NULL,
  norm_title        text NOT NULL,
  start_time        time NOT NULL,                       -- horario local
  freq              text NOT NULL CHECK (freq IN ('daily','weekly','monthly')),
  weekday           integer,                             -- 1 (segunda) a 7 (domingo), freq weekly
  dom               integer,                             -- dia do mes, freq monthly
  first_date        date NOT NULL,                       -- data local da primeira ocorrencia
  until             date,
  duration_min      integer NOT NULL DEFAULT 60,
  calendar_event_id text,
  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS agenda_series_user ON agenda_series (user_id, active);

ALTER TABLE reminders ADD COLUMN IF NOT EXISTS series_id bigint REFERENCES agenda_series(id) ON DELETE SET NULL;
ALTER TABLE reminders ADD COLUMN IF NOT EXISTS person text;

-- Convites ja avisados (nao repetir o aviso).
CREATE TABLE IF NOT EXISTS agenda_invites_seen (
  user_id  bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event_id text   NOT NULL,
  seen_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, event_id)
);

-- ---------------------------------------------------------------- auxiliares
CREATE OR REPLACE FUNCTION f_ag_ts(p text) RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE SET search_path TO 'agente', 'public' AS $$
BEGIN
  IF p IS NULL OR btrim(p) = '' THEN RETURN NULL; END IF;
  RETURN p::timestamptz;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION f_ag_iso(p timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente', 'public' AS $$
  SELECT to_char(p AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

CREATE OR REPLACE FUNCTION f_ag_dayname(p date) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente', 'public' AS $$
  SELECT (ARRAY['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow FROM p)::int + 1]
$$;

-- "sex 30/10 às 15:00"
CREATE OR REPLACE FUNCTION f_ag_fmt(p timestamptz, p_tz text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'agente', 'public' AS $$
  SELECT f_ag_dayname((p AT TIME ZONE p_tz)::date) || ' ' || to_char(p AT TIME ZONE p_tz, 'DD/MM') || ' às ' || to_char(p AT TIME ZONE p_tz, 'HH24:MI')
$$;

-- Compara a busca com o titulo: 1 = contem a frase (ou busca vazia), 2 = todas as palavras, 3 = alguma palavra, 0 = nada.
CREATE OR REPLACE FUNCTION f_ag_match(p_q text, p_t text) RETURNS int
LANGUAGE plpgsql IMMUTABLE SET search_path TO 'agente', 'public' AS $$
DECLARE qn text := f_norm(p_q); tn text := f_norm(p_t); toks text[];
BEGIN
  IF qn = '' THEN RETURN 1; END IF;
  IF position(qn IN tn) > 0 THEN RETURN 1; END IF;
  SELECT coalesce(array_agg(t), '{}') INTO toks
  FROM unnest(string_to_array(qn, ' ')) t
  WHERE length(t) >= 2 AND t NOT IN ('de','da','do','das','dos','a','o','as','os','e','com','no','na','nos','nas','em','para','pra','pro','um','uma','meu','minha','compromisso','evento','lembrete');
  IF cardinality(toks) = 0 THEN RETURN 0; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(toks) t WHERE position(t IN tn) = 0) THEN RETURN 2; END IF;
  IF EXISTS (SELECT 1 FROM unnest(toks) t WHERE position(t IN tn) > 0) THEN RETURN 3; END IF;
  RETURN 0;
END $$;

-- Lembretes do bot ligados a um evento (por id do Google, ou por titulo+horario se o id for nulo, ou pela serie).
-- p_scope 'a' = serie inteira; qualquer outro = so a ocorrencia que comeca em p_start.
CREATE OR REPLACE FUNCTION f_ag_links(p_user bigint, p_event text, p_rec text, p_title text, p_start timestamptz, p_scope text)
RETURNS bigint[] LANGUAGE sql STABLE SET search_path TO 'agente', 'public' AS $$
  SELECT coalesce(array_agg(r.id), '{}')
  FROM reminders r
  WHERE r.user_id = p_user AND r.status = 'pending'
    AND (
         (p_event <> '' AND r.calendar_event_id = p_event)
      OR (p_rec <> '' AND r.calendar_event_id = p_rec AND (p_scope = 'a' OR (r.due_at IS NOT NULL AND p_start IS NOT NULL AND abs(extract(epoch FROM r.due_at - p_start)) < 60)))
      OR (p_rec <> '' AND r.series_id IN (SELECT s.id FROM agenda_series s WHERE s.user_id = p_user AND s.calendar_event_id = p_rec)
          AND (p_scope = 'a' OR (r.due_at IS NOT NULL AND p_start IS NOT NULL AND abs(extract(epoch FROM r.due_at - p_start)) < 60)))
      OR (r.kind = 'event' AND r.calendar_event_id IS NULL AND f_norm(r.title) = f_norm(p_title)
          AND r.due_at IS NOT NULL AND p_start IS NOT NULL AND abs(extract(epoch FROM r.due_at - p_start)) < 60)
    )
$$;

-- Proxima ocorrencia (apos agora) de um compromisso recorrente; NULL se acabou ou nao existe.
CREATE OR REPLACE FUNCTION f_series_next(p_series bigint) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path TO 'agente', 'public' AS $$
DECLARE s agenda_series%ROWTYPE; tz text; v_today date; d date; ts timestamptz; i int; last_dom int;
BEGIN
  SELECT * INTO s FROM agenda_series WHERE id = p_series AND active;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT timezone INTO tz FROM users WHERE id = s.user_id;
  v_today := (now() AT TIME ZONE tz)::date;
  d := greatest(v_today, s.first_date);
  IF s.freq = 'daily' THEN
    ts := (d + s.start_time) AT TIME ZONE tz;
    IF ts <= now() THEN d := d + 1; END IF;
  ELSIF s.freq = 'weekly' THEN
    d := d + ((s.weekday - extract(isodow FROM d)::int + 7) % 7);
    ts := (d + s.start_time) AT TIME ZONE tz;
    IF ts <= now() THEN d := d + 7; END IF;
  ELSE
    d := NULL;
    FOR i IN 0..24 LOOP
      last_dom := extract(day FROM (date_trunc('month', greatest(v_today, s.first_date)) + make_interval(months => i + 1) - interval '1 day'))::int;
      d := (date_trunc('month', greatest(v_today, s.first_date)) + make_interval(months => i))::date + (least(s.dom, last_dom) - 1);
      IF d >= greatest(v_today, s.first_date) AND (d + s.start_time) AT TIME ZONE tz > now() THEN EXIT; END IF;
      d := NULL;
    END LOOP;
    IF d IS NULL THEN RETURN NULL; END IF;
  END IF;
  IF s.until IS NOT NULL AND d > s.until THEN RETURN NULL; END IF;
  RETURN (d + s.start_time) AT TIME ZONE tz;
END $$;

-- ---------------------------------------------------------------- texto de confirmacao de uma pendencia (move/cancel)
CREATE OR REPLACE FUNCTION f_ag_confirm(p_pid bigint) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE pd agenda_pending%ROWTYPE; tz text; t text; n int; conf text; rec boolean;
BEGIN
  SELECT * INTO pd FROM agenda_pending WHERE id = p_pid;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não encontrei essa ação.', 'kb', 'none'); END IF;
  SELECT timezone INTO tz FROM users WHERE id = pd.user_id;
  n := (CASE WHEN pd.payload->>'attendees' ~ '^[0-9]+$' THEN (pd.payload->>'attendees')::int ELSE 0 END);
  rec := coalesce(pd.payload->>'recurring_id', '') <> '';
  SELECT string_agg((c->>'title') || ' (' || to_char((c->>'start')::timestamptz AT TIME ZONE tz, 'HH24:MI') || '–' || to_char((c->>'end')::timestamptz AT TIME ZONE tz, 'HH24:MI') || ')', ', ')
    INTO conf FROM jsonb_array_elements(coalesce(pd.payload->'conflicts', '[]'::jsonb)) c;
  IF pd.kind = 'cancel' THEN
    IF rec THEN
      t := 'Cancelar "' || pd.title || '" (' || f_ag_fmt(pd.old_start, tz) || ')? Esse compromisso se repete: cancelo só este dia ou a série inteira?';
      IF n > 0 THEN t := t || ' Os ' || n || ' convidado(s) serão avisados pelo Google.'; END IF;
      RETURN jsonb_build_object('text', t, 'kb', 'ag_scope', 'rid', pd.id);
    END IF;
    t := 'Cancelar "' || pd.title || '" (' || f_ag_fmt(pd.old_start, tz) || ')? Apago do Google Agenda e cancelo os avisos que eu tinha.';
    IF n > 0 THEN t := t || ' Os ' || n || ' convidado(s) serão avisados pelo Google.'; END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'ag_confirm', 'rid', pd.id);
  ELSIF pd.kind = 'move' THEN
    t := 'Mover "' || pd.title || '" de ' || f_ag_fmt(pd.old_start, tz) || ' para ' || f_ag_fmt(pd.new_start, tz) || '?';
    IF rec THEN t := t || ' Esse compromisso se repete: movo só esta ocorrência, a série continua igual.'; END IF;
    IF n > 0 THEN t := t || ' Os ' || n || ' convidado(s) serão avisados pelo Google.'; END IF;
    IF conf IS NOT NULL THEN t := t || ' Atenção: conflita com ' || conf || '.'; END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'ag_confirm', 'rid', pd.id);
  END IF;
  RETURN jsonb_build_object('text', 'Confirmar?', 'kb', 'ag_confirm', 'rid', pd.id);
END $$;

-- ---------------------------------------------------------------- gerir agenda: mover, cancelar, horario livre, promover
-- p = {act, title, win_start, win_end, new_start, new_end, new_time, duration_minutes, min_minutes, part, calendar_key, ok, error, events:[...]}
CREATE OR REPLACE FUNCTION f_agenda_manage(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE
  u users%ROWTYPE; tz text; act text := lower(coalesce(p->>'act', '')); q text := btrim(coalesce(p->>'title', ''));
  ck text := coalesce(p->>'calendar_key', '');
  ev jsonb := CASE WHEN jsonb_typeof(p->'events') = 'array' THEN p->'events' ELSE '[]'::jsonb END;
  cands jsonb; n int; c jsonb; i int; grp uuid; pid bigint; pids bigint[] := '{}';
  v_st timestamptz; v_en timestamptz; v_ns timestamptz; v_ne timestamptz; v_dur int; v_nt time; conf jsonb; v_cnt int := 0;
  lines text := ''; d date; d0 date; d1 date; ps time; pe time; ts_s timestamptz; ts_e timestamptz; cur timestamptz; cur_now timestamptz;
  b record; mins int; part text; blocks text; nl text := E'\n'; any_free boolean := false; clamped boolean := false; label text; r reminders%ROWTYPE;
  rn int; rbest int;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não achei o seu cadastro.', 'kb', 'none'); END IF;
  tz := u.timezone;
  UPDATE agenda_pending SET state = 'cancelled' WHERE user_id = p_user AND state = 'open' AND kind <> 'respond' AND created_at < now() - interval '1 day';
  IF act NOT IN ('move', 'cancel', 'free', 'promote') THEN
    RETURN jsonb_build_object('text', 'Não entendi o que fazer na agenda. Diga, por exemplo: "muda a reunião de sexta para as 15h" ou "cancela o dentista".', 'kb', 'none');
  END IF;
  IF ck = '' THEN
    RETURN jsonb_build_object('text', 'Seu Google Calendar ainda não está conectado ao agente, então não consigo mexer na agenda por aqui.', 'kb', 'none');
  END IF;
  IF act <> 'promote' AND coalesce(p->>'ok', '') = 'false' THEN
    RETURN jsonb_build_object('text', 'Não consegui ler sua agenda agora' || CASE WHEN jsonb_typeof(p->'error') = 'string' THEN ' (' || left(p->>'error', 120) || ')' ELSE '' END || '. Tente de novo em instantes.', 'kb', 'none');
  END IF;

  -- ============================================================ cancelar / mover
  IF act IN ('cancel', 'move') THEN
    IF q = '' THEN
      RETURN jsonb_build_object('text', 'Qual compromisso? Me diga o nome (e o dia, se tiver mais de um).', 'kb', 'none');
    END IF;
    IF act = 'move' AND nullif(p->>'new_start', '') IS NULL AND nullif(p->>'new_time', '') IS NULL THEN
      RETURN jsonb_build_object('text', 'Para que horário eu movo "' || q || '"?', 'kb', 'none');
    END IF;
    WITH cc AS (
      SELECT e, f_ag_ts(e->>'start') st, f_ag_ts(e->>'end') en, coalesce(e->>'all_day', '') = 'true' ad, f_ag_match(q, e->>'title') m
      FROM jsonb_array_elements(ev) e
    ), ff AS (
      SELECT * FROM cc
      WHERE m > 0 AND st IS NOT NULL AND coalesce(e->>'self_status', '') <> 'declined' AND coalesce(e->>'id', '') <> ''
        AND (act = 'cancel' OR NOT ad)
        AND coalesce(en, st) > now() - (CASE WHEN ad THEN interval '1 day' ELSE interval '0' END)
    ), bm AS (SELECT min(m) mm FROM ff)
    SELECT jsonb_agg(jsonb_build_object('e', ff.e, 'st', ff.st, 'en', coalesce(ff.en, ff.st)) ORDER BY ff.st), count(*)
      INTO cands, n FROM ff, bm WHERE ff.m = bm.mm;
    IF n = 0 OR cands IS NULL THEN
      RETURN jsonb_build_object('text', 'Não achei nenhum compromisso com "' || q || '" no período buscado. Diga o dia ou o nome completo e eu tento de novo.', 'kb', 'none');
    END IF;
    IF n > 1 THEN grp := gen_random_uuid(); END IF;
    FOR i IN 0..least(n, 3) - 1 LOOP
      c := cands->i;
      v_st := (c->>'st')::timestamptz; v_en := (c->>'en')::timestamptz;
      conf := NULL; v_ns := NULL; v_ne := NULL;
      IF act = 'move' THEN
        v_ns := f_ag_ts(p->>'new_start');
        IF v_ns IS NULL THEN
          v_nt := (p->>'new_time')::time;
          v_ns := (((v_st AT TIME ZONE tz)::date + v_nt)::timestamp) AT TIME ZONE tz;
        END IF;
        v_dur := coalesce(nullif(p->>'duration_minutes', '')::int, round(extract(epoch FROM (v_en - v_st)) / 60)::int);
        IF v_dur IS NULL OR v_dur <= 0 THEN v_dur := 60; END IF;
        v_ne := v_ns + make_interval(mins => v_dur);
        IF v_ns <= now() THEN CONTINUE; END IF;
        SELECT jsonb_agg(jsonb_build_object('title', x->>'title', 'start', x->>'start', 'end', x->>'end')) INTO conf
        FROM jsonb_array_elements(ev) x
        WHERE coalesce(x->>'id', '') <> coalesce(c->'e'->>'id', '') AND coalesce(x->>'all_day', '') <> 'true'
          AND coalesce(x->>'self_status', '') <> 'declined'
          AND f_ag_ts(x->>'start') < v_ne AND f_ag_ts(x->>'end') > v_ns;
      END IF;
      INSERT INTO agenda_pending(user_id, kind, calendar_key, grp, event_id, title, old_start, old_end, new_start, new_end, payload)
      VALUES (p_user, act, ck, grp, c->'e'->>'id', coalesce(c->'e'->>'title', q), v_st, v_en, v_ns, v_ne,
              jsonb_build_object('recurring_id', coalesce(c->'e'->>'recurring_id', ''),
                                 'attendees', coalesce(nullif(c->'e'->>'attendees', '')::int, 0),
                                 'all_day', coalesce(c->'e'->>'all_day', '') = 'true',
                                 'location', coalesce(c->'e'->>'location', ''),
                                 'conflicts', coalesce(conf, '[]'::jsonb)))
      RETURNING id INTO pid;
      pids := pids || pid;
      v_cnt := v_cnt + 1;
      lines := lines || nl || v_cnt || ') ' || coalesce(c->'e'->>'title', q) || ' - ' || f_ag_fmt(v_st, tz);
    END LOOP;
    IF v_cnt = 0 THEN
      RETURN jsonb_build_object('text', 'Esse horário novo já passou. Para quando eu movo "' || q || '"?', 'kb', 'none');
    END IF;
    IF v_cnt = 1 THEN
      RETURN f_ag_confirm(pids[1]);
    END IF;
    RETURN jsonb_build_object('text', 'Achei ' || CASE WHEN n > 3 THEN 'mais de 3 compromissos (mostro os 3 mais próximos)' ELSE v_cnt || ' compromissos' END
                              || '. Qual deles?' || lines,
                              'kb', CASE WHEN v_cnt = 2 THEN 'ag_pick2' ELSE 'ag_pick3' END, 'rid', pids[1]);
  END IF;

  -- ============================================================ horario livre
  IF act = 'free' THEN
    d0 := coalesce((f_ag_ts(p->>'win_start') AT TIME ZONE tz)::date, f_fin_today(p_user));
    d1 := CASE WHEN f_ag_ts(p->>'win_end') IS NULL THEN d0 ELSE ((f_ag_ts(p->>'win_end') - interval '1 second') AT TIME ZONE tz)::date END;
    IF d1 < d0 THEN d1 := d0; END IF;
    IF d1 > d0 + 6 THEN d1 := d0 + 6; clamped := true; END IF;
    mins := least(greatest(coalesce(nullif(p->>'min_minutes', '')::int, 30), 5), 720);
    part := lower(btrim(coalesce(p->>'part', '')));
    label := CASE part WHEN 'manha' THEN ' (manhã)' WHEN 'tarde' THEN ' (tarde)' WHEN 'noite' THEN ' (noite)' ELSE '' END;
    cur_now := date_trunc('hour', now()) + ceil(extract(minute FROM now()) / 15.0) * interval '15 minutes';
    FOR d IN SELECT g::date FROM generate_series(d0::timestamp, d1::timestamp, interval '1 day') g LOOP
      IF part ~ '^[0-9]{1,2}:[0-9]{2}-[0-9]{1,2}:[0-9]{2}$' THEN
        ps := split_part(part, '-', 1)::time; pe := split_part(part, '-', 2)::time; label := ' (' || to_char(ps, 'HH24:MI') || '–' || to_char(pe, 'HH24:MI') || ')';
      ELSIF part = 'manha' THEN ps := u.work_start; pe := least(u.work_end, time '12:00');
      ELSIF part = 'tarde' THEN ps := greatest(u.work_start, time '12:00'); pe := u.work_end;
      ELSIF part = 'noite' THEN ps := u.work_end; pe := time '22:00';
      ELSE ps := u.work_start; pe := u.work_end; END IF;
      IF pe <= ps THEN CONTINUE; END IF;
      ts_s := (d + ps) AT TIME ZONE tz; ts_e := (d + pe) AT TIME ZONE tz;
      cur := greatest(ts_s, cur_now);
      IF cur >= ts_e THEN CONTINUE; END IF;
      blocks := '';
      FOR b IN SELECT f_ag_ts(x->>'start') st, f_ag_ts(x->>'end') en FROM jsonb_array_elements(ev) x
               WHERE coalesce(x->>'all_day', '') <> 'true' AND coalesce(x->>'self_status', '') <> 'declined'
                 AND f_ag_ts(x->>'start') IS NOT NULL AND f_ag_ts(x->>'end') IS NOT NULL
                 AND f_ag_ts(x->>'end') > cur AND f_ag_ts(x->>'start') < ts_e
               ORDER BY 1 LOOP
        IF b.st - cur >= make_interval(mins => mins) THEN
          blocks := blocks || CASE WHEN blocks = '' THEN '' ELSE ', ' END || to_char(cur AT TIME ZONE tz, 'HH24:MI') || '–' || to_char(b.st AT TIME ZONE tz, 'HH24:MI');
        END IF;
        cur := greatest(cur, b.en);
      END LOOP;
      IF ts_e - cur >= make_interval(mins => mins) THEN
        blocks := blocks || CASE WHEN blocks = '' THEN '' ELSE ', ' END || to_char(cur AT TIME ZONE tz, 'HH24:MI') || '–' || to_char(ts_e AT TIME ZONE tz, 'HH24:MI');
      END IF;
      IF blocks <> '' THEN
        lines := lines || nl || '- ' || f_ag_dayname(d) || ' ' || to_char(d, 'DD/MM') || ': ' || blocks;
        any_free := true;
      END IF;
    END LOOP;
    IF NOT any_free THEN
      RETURN jsonb_build_object('text', 'Não achei horário livre de pelo menos ' || mins || ' min' || label || CASE WHEN d0 = d1 THEN ' em ' || to_char(d0, 'DD/MM') ELSE ' entre ' || to_char(d0, 'DD/MM') || ' e ' || to_char(d1, 'DD/MM') END
        || ' (expediente ' || to_char(u.work_start, 'HH24:MI') || '–' || to_char(u.work_end, 'HH24:MI') || ').', 'kb', 'none');
    END IF;
    RETURN jsonb_build_object('text', 'Horários livres' || label || ' (blocos de pelo menos ' || mins || ' min, expediente ' || to_char(u.work_start, 'HH24:MI') || '–' || to_char(u.work_end, 'HH24:MI') || '):' || lines
      || CASE WHEN clamped THEN nl || 'Mostrei só os primeiros 7 dias.' ELSE '' END, 'kb', 'none');
  END IF;

  -- ============================================================ lembrete vira compromisso
  IF act = 'promote' THEN
    IF q = '' THEN
      RETURN jsonb_build_object('text', 'Qual lembrete eu coloco no Google Agenda? Me diga o nome.', 'kb', 'none');
    END IF;
    SELECT min(f_ag_match(q, title)) FILTER (WHERE f_ag_match(q, title) > 0), count(*) FILTER (WHERE f_ag_match(q, title) > 0)
      INTO rbest, rn FROM reminders WHERE user_id = p_user AND kind = 'reminder' AND status = 'pending' AND due_at > now();
    IF rn = 0 OR rbest IS NULL THEN
      RETURN jsonb_build_object('text', 'Não achei nenhum lembrete pendente com "' || q || '".', 'kb', 'none');
    END IF;
    SELECT * INTO r FROM reminders WHERE user_id = p_user AND kind = 'reminder' AND status = 'pending' AND due_at > now()
      AND f_ag_match(q, title) = rbest ORDER BY due_at LIMIT 1;
    v_dur := coalesce(nullif(p->>'duration_minutes', '')::int, 60);
    INSERT INTO agenda_pending(user_id, kind, calendar_key, title, new_start, new_end, payload)
    VALUES (p_user, 'create', ck, r.title, r.due_at, r.due_at + make_interval(mins => v_dur),
            jsonb_build_object('summary', r.title, 'start', f_ag_iso(r.due_at), 'end', f_ag_iso(r.due_at + make_interval(mins => v_dur)),
                               'location', '', 'attendees', '', 'meet', false, 'repeat_freq', '', 'repeat_until', '', 'repeat_count', '',
                               'lead_str', '', 'source', 'text', 'force', false, 'promote_reminder_id', r.id))
    RETURNING id INTO pid;
    RETURN jsonb_build_object('text', 'Criar "' || r.title || '" no seu Google Agenda em ' || f_ag_fmt(r.due_at, tz) || ' (' || v_dur || ' min)? O lembrete daqui continua ativo.'
                              || CASE WHEN rn > 1 THEN ' (Achei ' || rn || ' lembretes parecidos; peguei o mais próximo.)' ELSE '' END,
                              'kb', 'ag_confirm', 'rid', pid);
  END IF;
  RETURN jsonb_build_object('text', 'Não entendi o pedido de agenda.', 'kb', 'none');
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('text', 'Não consegui mexer na agenda agora. Tente de novo em instantes.', 'kb', 'none', 'err', SQLERRM);
END $$;

-- ---------------------------------------------------------------- monta o pedido ao subworkflow de calendario
CREATE OR REPLACE FUNCTION f_ag_cal(pd agenda_pending, p_scope text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente', 'public' AS $$
DECLARE n int := (CASE WHEN pd.payload->>'attendees' ~ '^[0-9]+$' THEN (pd.payload->>'attendees')::int ELSE 0 END); pl jsonb := pd.payload; att text;
BEGIN
  IF pd.kind = 'move' THEN
    RETURN jsonb_build_object('op', 'update', 'calendar_key', pd.calendar_key, 'pid', pd.id, 'event_id', pd.event_id,
      'start', f_ag_iso(pd.new_start), 'end', f_ag_iso(pd.new_end), 'send_updates', CASE WHEN n > 0 THEN 'all' ELSE 'none' END);
  ELSIF pd.kind = 'cancel' THEN
    RETURN jsonb_build_object('op', 'delete', 'calendar_key', pd.calendar_key, 'pid', pd.id,
      'event_id', CASE WHEN p_scope = 'a' AND coalesce(pl->>'recurring_id', '') <> '' THEN pl->>'recurring_id' ELSE pd.event_id END,
      'send_updates', CASE WHEN n > 0 THEN 'all' ELSE 'none' END);
  ELSIF pd.kind = 'create' THEN
    att := coalesce(pl->>'attendees', '');
    RETURN jsonb_build_object('op', 'create', 'calendar_key', pd.calendar_key, 'pid', pd.id,
      'summary', coalesce(pl->>'summary', pd.title), 'start', coalesce(pl->>'start', f_ag_iso(pd.new_start)), 'end', coalesce(pl->>'end', f_ag_iso(pd.new_end)),
      'location', coalesce(pl->>'location', ''), 'attendees', att,
      'meet', CASE WHEN coalesce(pl->>'meet', 'false') = 'true' THEN 'true' ELSE 'false' END,
      'repeat_freq', coalesce(pl->>'repeat_freq', ''), 'repeat_until', coalesce(pl->>'repeat_until', ''), 'repeat_count', coalesce(pl->>'repeat_count', ''),
      'force', CASE WHEN coalesce(pl->>'force', 'false') = 'true' THEN 'true' ELSE 'false' END,
      'send_updates', CASE WHEN att <> '' THEN 'all' ELSE 'none' END);
  ELSIF pd.kind = 'respond' THEN
    RETURN jsonb_build_object('op', 'respond', 'calendar_key', pd.calendar_key, 'pid', pd.id, 'event_id', pd.event_id,
      'response', coalesce(pl->>'response', 'accepted'));
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------- botoes da agenda
CREATE OR REPLACE FUNCTION f_agenda_cb(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE
  a text := split_part(p_data, ':', 1); v_id bigint := nullif(split_part(p_data, ':', 2), '')::bigint; v3 text := split_part(p_data, ':', 3);
  pd agenda_pending%ROWTYPE; pk agenda_pending%ROWTYPE; tz text; cal jsonb; idx int; t text; orig text;
  gone jsonb := jsonb_build_object('text', 'Essa ação já foi resolvida ou expirou.', 'kb', 'none');
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  IF a NOT IN ('agok', 'agno', 'agpk', 'agsc', 'agfy', 'agfo', 'agrs', 'agrn') THEN
    RETURN jsonb_build_object('text', 'Não entendi esse botão.', 'kb', 'none');
  END IF;
  SELECT * INTO pd FROM agenda_pending WHERE id = v_id AND user_id = p_user AND state = 'open';
  IF NOT FOUND THEN RETURN gone; END IF;

  IF a = 'agno' THEN
    UPDATE agenda_pending SET state = 'cancelled' WHERE user_id = p_user AND state = 'open' AND (id = pd.id OR (pd.grp IS NOT NULL AND grp = pd.grp));
    RETURN jsonb_build_object('text', CASE pd.kind WHEN 'move' THEN 'Ok, não movi nada.' WHEN 'cancel' THEN 'Ok, não cancelei nada.'
                                                    WHEN 'create' THEN 'Ok, não marquei nada.' ELSE 'Ok.' END, 'kb', 'none');
  END IF;

  IF a = 'agpk' THEN
    idx := coalesce(nullif(v3, '')::int, 0);
    IF pd.grp IS NULL THEN SELECT * INTO pk FROM agenda_pending WHERE id = pd.id;
    ELSE
      SELECT * INTO pk FROM agenda_pending WHERE id = (SELECT s.id FROM (SELECT x.id, row_number() OVER (ORDER BY x.id) rn FROM agenda_pending x
                             WHERE x.user_id = p_user AND x.grp = pd.grp AND x.state = 'open') s WHERE s.rn = idx);
    END IF;
    IF pk.id IS NULL THEN RETURN jsonb_build_object('text', 'Não achei essa opção. Peça de novo.', 'kb', 'none'); END IF;
    UPDATE agenda_pending SET state = 'cancelled' WHERE user_id = p_user AND state = 'open' AND grp IS NOT NULL AND grp = pd.grp AND id <> pk.id;
    RETURN f_ag_confirm(pk.id);
  END IF;

  IF a IN ('agrs', 'agrn') THEN
    IF pd.kind <> 'respond' THEN RETURN gone; END IF;
    UPDATE agenda_pending SET payload = payload || jsonb_build_object('response', CASE WHEN a = 'agrs' THEN 'accepted' ELSE 'declined' END, 'dispatched_at', now()) WHERE id = pd.id RETURNING * INTO pd;
    RETURN jsonb_build_object('text', 'Respondendo ao convite...', 'kb', 'none', 'cal', f_ag_cal(pd, ''));
  END IF;

  IF a = 'agfo' THEN
    IF pd.kind <> 'create' THEN RETURN gone; END IF;
    UPDATE agenda_pending SET state = 'cancelled' WHERE id = pd.id;
    orig := 'Marcar "' || coalesce(pd.payload->>'summary', pd.title) || '" em outro horário (o pedido antes era ' || f_ag_fmt(coalesce(f_ag_ts(pd.payload->>'start'), pd.new_start), tz)
         || ', duração ' || round(extract(epoch FROM (coalesce(f_ag_ts(pd.payload->>'end'), pd.new_end) - coalesce(f_ag_ts(pd.payload->>'start'), pd.new_start))) / 60)::int || ' min'
         || CASE WHEN coalesce(pd.payload->>'location', '') <> '' THEN ', local ' || (pd.payload->>'location') ELSE '' END
         || CASE WHEN coalesce(pd.payload->>'repeat_freq', '') <> '' THEN ', repete ' || (pd.payload->>'repeat_freq') ELSE '' END || ')';
    RETURN jsonb_build_object('text', 'Ok. Qual outro horário para "' || coalesce(pd.payload->>'summary', pd.title) || '"? Me diga o dia e a hora.', 'kb', 'none',
                              'state', jsonb_build_object('kind', 'clarify', 'original', orig)::text);
  END IF;

  -- agok, agsc, agfy: executam algo no Google (protecao contra toque duplo: 60 s)
  IF coalesce(f_ag_ts(pd.payload->>'dispatched_at'), '-infinity') > now() - interval '60 seconds' THEN
    RETURN jsonb_build_object('text', 'Já estou cuidando disso, só um instante.', 'kb', 'none');
  END IF;
  IF a = 'agsc' THEN
    IF pd.kind <> 'cancel' OR v3 NOT IN ('1', 'a') THEN RETURN gone; END IF;
    UPDATE agenda_pending SET payload = payload || jsonb_build_object('scope', v3, 'dispatched_at', now()) WHERE id = pd.id RETURNING * INTO pd;
    RETURN jsonb_build_object('text', 'Cancelando...', 'kb', 'none', 'cal', f_ag_cal(pd, v3));
  ELSIF a = 'agfy' THEN
    IF pd.kind <> 'create' THEN RETURN gone; END IF;
    UPDATE agenda_pending SET payload = payload || jsonb_build_object('force', true, 'dispatched_at', now()) WHERE id = pd.id RETURNING * INTO pd;
    RETURN jsonb_build_object('text', 'Marcando mesmo assim...', 'kb', 'none', 'cal', f_ag_cal(pd, ''));
  ELSE -- agok
    IF pd.kind = 'respond' THEN RETURN gone; END IF;
    IF pd.kind = 'cancel' AND coalesce(pd.payload->>'recurring_id', '') <> '' AND coalesce(pd.payload->>'scope', '') = '' THEN
      RETURN f_ag_confirm(pd.id);   -- recorrente: precisa do escopo antes
    END IF;
    UPDATE agenda_pending SET payload = payload || jsonb_build_object('dispatched_at', now()) WHERE id = pd.id RETURNING * INTO pd;
    RETURN jsonb_build_object('text', 'Certo, fazendo...', 'kb', 'none', 'cal', f_ag_cal(pd, coalesce(pd.payload->>'scope', '')));
  END IF;
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('text', 'Não consegui processar esse botão agora. Tente de novo.', 'kb', 'none', 'err', SQLERRM);
END $$;

-- ---------------------------------------------------------------- depois do Google responder a uma acao dos botoes
CREATE OR REPLACE FUNCTION f_agenda_done(p_user bigint, p_pid bigint, p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE
  pd agenda_pending%ROWTYPE; tz text; ok boolean; v_ids bigint[]; rid bigint; offs int[]; o int; v_kind text; t text; n_av int := 0;
  scope text; req jsonb; conf text; err text; rec text;
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  SELECT * INTO pd FROM agenda_pending WHERE id = p_pid AND user_id = p_user;
  IF NOT FOUND OR pd.state <> 'open' THEN
    RETURN jsonb_build_object('text', 'Essa ação já foi resolvida.', 'kb', 'none', 'rid', 0);
  END IF;
  ok := coalesce(p_result->>'ok', '') = 'true';
  IF NOT ok THEN
    err := CASE WHEN jsonb_typeof(p_result->'error') = 'string' THEN left(p_result->>'error', 140) ELSE NULL END;
    UPDATE agenda_pending SET payload = payload - 'dispatched_at' WHERE id = pd.id;
    RETURN jsonb_build_object('text', 'Não consegui fazer isso no Google Agenda' || CASE WHEN err IS NOT NULL THEN ' (' || err || ')' ELSE '' END
                              || '. Nada foi alterado; pode tentar de novo.', 'kb', 'none', 'rid', 0);
  END IF;
  rec := coalesce(pd.payload->>'recurring_id', '');
  scope := coalesce(pd.payload->>'scope', '');

  IF pd.kind = 'create' THEN
    IF coalesce(p_result->>'conflict', '') = 'true' THEN
      UPDATE agenda_pending SET payload = (payload - 'dispatched_at') || jsonb_build_object('conflicts', coalesce(p_result->'conflicts', '[]'::jsonb), 'force', false) WHERE id = pd.id;
      SELECT string_agg((c->>'title') || ' (' || to_char(f_ag_ts(c->>'start') AT TIME ZONE tz, 'HH24:MI') || '–' || to_char(f_ag_ts(c->>'end') AT TIME ZONE tz, 'HH24:MI') || ')', ', ')
        INTO conf FROM jsonb_array_elements(coalesce(p_result->'conflicts', '[]'::jsonb)) c;
      RETURN jsonb_build_object('text', 'Atenção: "' || coalesce(pd.payload->>'summary', pd.title) || '" (' || f_ag_fmt(coalesce(f_ag_ts(pd.payload->>'start'), pd.new_start), tz)
                                || ') conflita com ' || coalesce(conf, 'outro compromisso') || '. Marco mesmo assim?', 'kb', 'ag_conflict', 'rid', pd.id);
    END IF;
    UPDATE agenda_pending SET state = 'done' WHERE id = pd.id;
    req := jsonb_build_object('title', coalesce(pd.payload->>'summary', pd.title), 'due_iso', coalesce(pd.payload->>'start', f_ag_iso(pd.new_start)),
      'end_iso', coalesce(pd.payload->>'end', f_ag_iso(pd.new_end)), 'location', coalesce(pd.payload->>'location', ''),
      'lead_str', coalesce(pd.payload->>'lead_str', ''), 'source', coalesce(pd.payload->>'source', 'text'), 'calendar_key', pd.calendar_key,
      'repeat_freq', coalesce(pd.payload->>'repeat_freq', ''), 'repeat_until', coalesce(pd.payload->>'repeat_until', ''),
      'repeat_count', coalesce(pd.payload->>'repeat_count', ''), 'attendees', coalesce(pd.payload->>'attendees', ''),
      'meet', coalesce(pd.payload->>'meet', 'false'), 'promote_reminder_id', pd.payload->'promote_reminder_id');
    RETURN f_agenda_after_create(p_user, req, p_result || jsonb_build_object('conflict', false));

  ELSIF pd.kind = 'move' THEN
    v_ids := f_ag_links(p_user, pd.event_id, rec, pd.title, pd.old_start, '1');
    FOREACH rid IN ARRAY v_ids LOOP
      SELECT kind INTO v_kind FROM reminders WHERE id = rid;
      SELECT array_agg(DISTINCT offset_minutes) INTO offs FROM notifications
        WHERE reminder_id = rid AND type = 'pre_alert' AND state <> 'cancelled' AND offset_minutes > 0;
      UPDATE notifications SET state = 'cancelled' WHERE reminder_id = rid AND state = 'pending' AND type IN ('pre_alert', 'reminder', 'repeat');
      UPDATE reminders SET due_at = pd.new_start WHERE id = rid;
      IF v_kind = 'reminder' THEN
        INSERT INTO notifications(user_id, reminder_id, type, fire_at) VALUES (p_user, rid, 'reminder', pd.new_start);
      END IF;
      IF offs IS NOT NULL THEN
        FOREACH o IN ARRAY offs LOOP
          IF pd.new_start - make_interval(mins => o) > now() THEN
            INSERT INTO notifications(user_id, reminder_id, type, fire_at, offset_minutes)
            VALUES (p_user, rid, 'pre_alert', pd.new_start - make_interval(mins => o), o);
          END IF;
        END LOOP;
      END IF;
      n_av := n_av + 1;
    END LOOP;
    UPDATE agenda_pending SET state = 'done' WHERE id = pd.id;
    UPDATE agenda_pending SET state = 'cancelled' WHERE user_id = p_user AND state = 'open' AND grp IS NOT NULL AND grp = pd.grp AND id <> pd.id;
    t := 'Pronto, movi "' || pd.title || '" para ' || f_ag_fmt(pd.new_start, tz) || '.';
    IF rec <> '' THEN t := t || ' Só esta ocorrência; a série continua igual.'; END IF;
    IF n_av > 0 THEN t := t || ' Ajustei os avisos daqui também.'; END IF;
    IF (CASE WHEN pd.payload->>'attendees' ~ '^[0-9]+$' THEN (pd.payload->>'attendees')::int ELSE 0 END) > 0 THEN t := t || ' Os convidados foram avisados.'; END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'none', 'rid', 0);

  ELSIF pd.kind = 'cancel' THEN
    v_ids := f_ag_links(p_user, CASE WHEN scope = 'a' THEN rec ELSE pd.event_id END, rec, pd.title, pd.old_start, CASE WHEN scope = 'a' THEN 'a' ELSE '1' END);
    UPDATE reminders SET status = 'cancelled' WHERE id = ANY (v_ids);
    UPDATE notifications SET state = 'cancelled' WHERE reminder_id = ANY (v_ids) AND state = 'pending';
    n_av := cardinality(v_ids);
    IF scope = 'a' AND rec <> '' THEN
      UPDATE agenda_series SET active = false WHERE user_id = p_user AND calendar_event_id = rec;
    END IF;
    UPDATE agenda_pending SET state = 'done' WHERE id = pd.id;
    UPDATE agenda_pending SET state = 'cancelled' WHERE user_id = p_user AND state = 'open' AND grp IS NOT NULL AND grp = pd.grp AND id <> pd.id;
    t := 'Cancelei "' || pd.title || '"' || CASE WHEN scope = 'a' THEN ' (a série inteira)' WHEN rec <> '' THEN ' (só ' || f_ag_fmt(pd.old_start, tz) || ')' ELSE ' (' || f_ag_fmt(pd.old_start, tz) || ')' END || ' no Google Agenda.';
    IF n_av > 0 THEN t := t || ' Cancelei ' || n_av || ' aviso(s)/lembrete(s) daqui.'; END IF;
    IF (CASE WHEN pd.payload->>'attendees' ~ '^[0-9]+$' THEN (pd.payload->>'attendees')::int ELSE 0 END) > 0 THEN t := t || ' Os convidados foram avisados.'; END IF;
    RETURN jsonb_build_object('text', t, 'kb', 'none', 'rid', 0);

  ELSIF pd.kind = 'respond' THEN
    UPDATE agenda_pending SET state = 'done' WHERE id = pd.id;
    RETURN jsonb_build_object('text', CASE WHEN coalesce(pd.payload->>'response', '') = 'declined' THEN 'Recusei' ELSE 'Aceitei' END
                              || ' o convite "' || pd.title || '" (' || f_ag_fmt(pd.old_start, tz) || ').', 'kb', 'none', 'rid', 0);
  END IF;
  RETURN jsonb_build_object('text', 'Pronto.', 'kb', 'none', 'rid', 0);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('text', 'O Google respondeu, mas tive um problema ao atualizar meus registros. Confira sua agenda.', 'kb', 'none', 'rid', 0, 'err', SQLERRM);
END $$;

-- ---------------------------------------------------------------- depois de criar um evento (fluxo normal)
-- p_req = {title, due_iso, end_iso, location, lead_str, source, calendar_key, repeat_freq, repeat_until, repeat_count, attendees, meet, promote_reminder_id}
CREATE OR REPLACE FUNCTION f_agenda_after_create(p_user bigint, p_req jsonb, p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE
  tz text; v_due timestamptz := f_ag_ts(p_req->>'due_iso'); v_fin timestamptz := f_ag_ts(p_req->>'end_iso');
  v_title text := coalesce(p_req->>'title', ''); v_freq text := coalesce(p_req->>'repeat_freq', ''); v_ev text := nullif(p_result->>'event_id', '');
  v_rem jsonb; v_rid bigint; v_lead int := nullif(p_req->>'lead_str', '')::int; t text := ''; kb text := 'none'; conf text; pid bigint;
  v_until date; v_count int; v_first date; v_promote bigint := nullif(p_req->>'promote_reminder_id', '')::bigint; err text; v_att text := coalesce(p_req->>'attendees', '');
  nl text := E'\n';
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  IF coalesce(p_result->>'ok', '') <> 'true' THEN
    err := CASE WHEN jsonb_typeof(p_result->'error') = 'string' THEN left(p_result->>'error', 140) ELSE NULL END;
    RETURN jsonb_build_object('text', 'Não consegui criar "' || v_title || '" no Google Agenda' || CASE WHEN err IS NOT NULL THEN ' (' || err || ')' ELSE '' END
                              || '. Nada foi marcado; pode tentar de novo.', 'kb', 'none', 'rid', 0);
  END IF;
  IF coalesce(p_result->>'conflict', '') = 'true' THEN
    INSERT INTO agenda_pending(user_id, kind, calendar_key, title, new_start, new_end, payload)
    VALUES (p_user, 'create', coalesce(p_req->>'calendar_key', ''), v_title, v_due, v_fin,
            jsonb_build_object('summary', v_title, 'start', p_req->>'due_iso', 'end', p_req->>'end_iso', 'location', coalesce(p_req->>'location', ''),
                               'attendees', v_att, 'meet', coalesce(p_req->>'meet', 'false') = 'true', 'repeat_freq', v_freq,
                               'repeat_until', coalesce(p_req->>'repeat_until', ''), 'repeat_count', coalesce(p_req->>'repeat_count', ''),
                               'lead_str', coalesce(p_req->>'lead_str', ''), 'source', coalesce(p_req->>'source', 'text'), 'force', false,
                               'conflicts', coalesce(p_result->'conflicts', '[]'::jsonb), 'promote_reminder_id', p_req->'promote_reminder_id'))
    RETURNING id INTO pid;
    SELECT string_agg((c->>'title') || ' (' || to_char(f_ag_ts(c->>'start') AT TIME ZONE tz, 'HH24:MI') || '–' || to_char(f_ag_ts(c->>'end') AT TIME ZONE tz, 'HH24:MI') || ')', ', ')
      INTO conf FROM jsonb_array_elements(coalesce(p_result->'conflicts', '[]'::jsonb)) c;
    RETURN jsonb_build_object('text', 'Atenção: "' || v_title || '" (' || f_ag_fmt(v_due, tz) || ') conflita com ' || coalesce(conf, 'outro compromisso') || '. Marco mesmo assim?',
                              'kb', 'ag_conflict', 'rid', pid);
  END IF;

  IF v_promote IS NOT NULL THEN
    UPDATE reminders SET calendar_event_id = v_ev WHERE id = v_promote AND user_id = p_user;
  ELSE
    v_rem := f_create_reminder(p_user, v_title, v_due, false, v_lead, 'event', v_ev, coalesce(nullif(p_req->>'source', ''), 'text'));
    v_rid := (v_rem->>'reminder_id')::bigint;
    IF coalesce((v_rem->>'ask_lead')::boolean, false) THEN kb := 'lead'; END IF;
  END IF;

  IF v_freq IN ('daily', 'weekly', 'monthly') AND v_due IS NOT NULL THEN
    v_first := (v_due AT TIME ZONE tz)::date;
    v_until := CASE WHEN coalesce(p_req->>'repeat_until', '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN (p_req->>'repeat_until')::date END;
    v_count := nullif(p_req->>'repeat_count', '')::int;
    IF v_until IS NULL AND v_count IS NOT NULL AND v_count > 0 THEN
      v_until := CASE v_freq WHEN 'daily' THEN v_first + (v_count - 1) WHEN 'weekly' THEN v_first + 7 * (v_count - 1)
                           ELSE (v_first + make_interval(months => v_count - 1))::date END;
    END IF;
    INSERT INTO agenda_series(user_id, title, norm_title, start_time, freq, weekday, dom, first_date, until, duration_min, calendar_event_id)
    VALUES (p_user, v_title, f_norm(v_title), (v_due AT TIME ZONE tz)::time, v_freq, extract(isodow FROM v_first)::int, extract(day FROM v_first)::int, v_first, v_until,
            coalesce(round(extract(epoch FROM (v_fin - v_due)) / 60)::int, 60), v_ev);
  END IF;

  t := 'Agendado no seu Google Calendar: "' || v_title || '" - ' || f_ag_fmt(v_due, tz)
       || CASE WHEN coalesce(p_req->>'location', '') <> '' THEN ' em ' || (p_req->>'location') ELSE '' END || '.';
  IF v_freq IN ('daily', 'weekly', 'monthly') THEN
    t := t || nl || 'Repete ' || CASE v_freq WHEN 'daily' THEN 'todo dia' WHEN 'weekly' THEN 'toda semana (' || f_ag_dayname((v_due AT TIME ZONE tz)::date) || ')'
                                      ELSE 'todo mês (dia ' || extract(day FROM (v_due AT TIME ZONE tz))::int || ')' END
         || CASE WHEN v_until IS NOT NULL THEN ', até ' || to_char(v_until, 'DD/MM/YYYY') ELSE '' END || '.';
  END IF;
  IF v_att <> '' THEN t := t || nl || 'Os convidados foram avisados pelo Google.'; END IF;
  IF nullif(p_result->>'meet_link', '') IS NOT NULL THEN t := t || nl || 'Meet: ' || (p_result->>'meet_link'); END IF;
  IF v_lead IS NOT NULL AND v_lead > 0 AND v_promote IS NULL THEN t := t || nl || 'Aviso ' || v_lead || ' min antes' || CASE WHEN v_freq <> '' THEN ' (só da próxima ocorrência)' ELSE '' END || '.'; END IF;
  IF v_promote IS NOT NULL THEN t := t || nl || 'Seu lembrete daqui continua ativo.'; END IF;
  IF kb = 'lead' THEN t := t || nl || 'Quer que eu te lembre antes?'; END IF;
  RETURN jsonb_build_object('text', t, 'kb', kb, 'rid', coalesce(v_rid, 0));
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('text', 'O evento foi criado no Google, mas tive um problema ao registrar os avisos aqui. Confira sua agenda.', 'kb', 'none', 'rid', 0, 'err', SQLERRM);
END $$;

-- ---------------------------------------------------------------- lembrete ligado a compromisso (e pessoa)
-- p = {title, link_event, person, lead_minutes, source}
CREATE OR REPLACE FUNCTION f_reminder_link(p_user bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE
  u users%ROWTYPE; tz text; q text := btrim(coalesce(p->>'link_event', '')); v_title text := btrim(coalesce(p->>'title', '')); v_person text := btrim(coalesce(p->>'person', ''));
  s agenda_series%ROWTYPE; s_next timestamptz; s_best int; r_ev reminders%ROWTYPE; r_best int; occ timestamptz; occ_title text; v_sid bigint;
  v_lead int; v_rem jsonb; v_rid bigint; cn text; cnt int; t text;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('text', 'Não achei o seu cadastro.', 'kb', 'none'); END IF;
  tz := u.timezone;
  IF v_title = '' THEN v_title := 'Lembrete de ' || q; END IF;
  -- 1) serie recorrente (a de proxima ocorrencia mais cedo entre as que melhor combinam)
  SELECT min(f_ag_match(q, x.title)) INTO s_best FROM agenda_series x WHERE x.user_id = p_user AND x.active AND f_series_next(x.id) IS NOT NULL AND f_ag_match(q, x.title) > 0;
  IF s_best IS NOT NULL THEN
    SELECT * INTO s FROM agenda_series x
      WHERE x.user_id = p_user AND x.active AND f_ag_match(q, x.title) = s_best AND f_series_next(x.id) IS NOT NULL
      ORDER BY f_series_next(x.id) LIMIT 1;
    s_next := f_series_next(s.id);
  END IF;
  -- 2) evento unico (espelho em reminders kind=event)
  SELECT min(f_ag_match(q, x.title)) INTO r_best FROM reminders x WHERE x.user_id = p_user AND x.kind = 'event' AND x.status = 'pending' AND x.due_at > now() AND f_ag_match(q, x.title) > 0;
  IF r_best IS NOT NULL THEN
    SELECT * INTO r_ev FROM reminders x WHERE x.user_id = p_user AND x.kind = 'event' AND x.status = 'pending' AND x.due_at > now() AND f_ag_match(q, x.title) = r_best ORDER BY x.due_at LIMIT 1;
  END IF;
  IF s_next IS NOT NULL AND (r_ev.id IS NULL OR s_next <= r_ev.due_at) THEN
    occ := s_next; occ_title := s.title; v_sid := s.id;
  ELSIF r_ev.id IS NOT NULL THEN
    occ := r_ev.due_at; occ_title := r_ev.title;
  END IF;
  IF occ IS NULL THEN
    RETURN jsonb_build_object('text', 'Não achei o compromisso "' || q || '" na sua agenda. Me diga a data e a hora que eu crio o lembrete "' || v_title || '".', 'kb', 'none', 'rid', 0,
      'state', jsonb_build_object('kind', 'clarify', 'original', 'Lembrete "' || v_title || '"' || CASE WHEN v_person <> '' THEN ' (para ' || v_person || ')' ELSE '' END || ' ligado ao compromisso "' || q || '", que não encontrei; falta a data e a hora')::text);
  END IF;
  -- pessoa: casa com os contatos pelo nome
  IF v_person <> '' THEN
    SELECT c.name INTO cn FROM contacts c WHERE c.user_id = p_user AND f_norm(c.name) = f_norm(v_person) LIMIT 1;
    IF cn IS NULL THEN
      SELECT count(*) INTO cnt FROM contacts c WHERE c.user_id = p_user AND f_norm(c.name) LIKE f_norm(v_person) || '%';
      IF cnt = 1 THEN SELECT c.name INTO cn FROM contacts c WHERE c.user_id = p_user AND f_norm(c.name) LIKE f_norm(v_person) || '%'; END IF;
    END IF;
    IF cn IS NOT NULL THEN v_person := initcap(cn); END IF;
  END IF;
  v_lead := CASE WHEN coalesce(nullif(p->>'lead_minutes', '')::int, 0) > 0 THEN (p->>'lead_minutes')::int
                WHEN coalesce(u.default_lead_minutes, 0) > 0 THEN u.default_lead_minutes ELSE 60 END;
  v_rem := f_create_reminder(p_user, v_title, occ, false, v_lead, 'reminder', NULL, coalesce(nullif(p->>'source', ''), 'text'));
  v_rid := (v_rem->>'reminder_id')::bigint;
  UPDATE reminders SET series_id = v_sid, person = nullif(v_person, ''), notes = 'Compromisso: ' || occ_title WHERE id = v_rid;
  t := 'Lembrete ligado a ' || occ_title || ' (' || f_ag_fmt(occ, tz) || ')' || CASE WHEN v_person <> '' THEN ' e a ' || v_person ELSE '' END || ': "' || v_title || '".'
       || ' Aviso ' || v_lead || ' min antes.'
       || CASE WHEN v_sid IS NOT NULL THEN ' Vale só para essa próxima ocorrência; depois dela, me peça de novo.' ELSE '' END;
  RETURN jsonb_build_object('text', t, 'kb', 'none', 'rid', v_rid, 'person_matched', cn IS NOT NULL);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('text', 'Não consegui ligar o lembrete ao compromisso agora. Tente de novo.', 'kb', 'none', 'rid', 0, 'err', SQLERRM);
END $$;

-- ---------------------------------------------------------------- convites recebidos (chamada pelo Disparador)
-- Devolve array de {chat_id, text, rid}. Cada convite so e avisado uma vez.
CREATE OR REPLACE FUNCTION f_agenda_invites(p_user bigint, p_cal text, p_events jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE
  u users%ROWTYPE; e jsonb; res jsonb := '[]'::jsonb; key text; st timestamptz; en timestamptz; pid bigint; org text; orgn text; cnt int := 0; ins int; t text;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user;
  IF NOT FOUND OR jsonb_typeof(p_events) <> 'array' THEN RETURN '[]'::jsonb; END IF;
  FOR e IN SELECT x FROM jsonb_array_elements(p_events) x
           WHERE coalesce(x->>'self_status', '') = 'needsAction' AND coalesce(x->>'organizer_self', 'false') <> 'true' AND coalesce(x->>'id', '') <> ''
           ORDER BY f_ag_ts(x->>'start') LOOP
    EXIT WHEN cnt >= 5;
    st := f_ag_ts(e->>'start'); en := coalesce(f_ag_ts(e->>'end'), st);
    IF st IS NULL OR en <= now() THEN CONTINUE; END IF;
    key := coalesce(nullif(e->>'recurring_id', ''), e->>'id');
    INSERT INTO agenda_invites_seen(user_id, event_id) VALUES (p_user, key) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS ins = ROW_COUNT;
    IF ins = 0 THEN CONTINUE; END IF;
    org := coalesce(nullif(e->>'organizer', ''), 'alguém');
    SELECT initcap(name) INTO orgn FROM contacts WHERE user_id = p_user AND lower(email) = lower(org) LIMIT 1;
    INSERT INTO agenda_pending(user_id, kind, calendar_key, event_id, title, old_start, old_end, payload)
    VALUES (p_user, 'respond', p_cal, key, coalesce(e->>'title', '(sem título)'), st, en,
            jsonb_build_object('organizer', org, 'recurring', coalesce(e->>'recurring_id', '') <> ''))
    RETURNING id INTO pid;
    t := 'Convite de ' || coalesce(orgn || ' (' || org || ')', org) || ': ' || coalesce(e->>'title', '(sem título)') || ', ' || f_ag_fmt(st, u.timezone)
         || CASE WHEN coalesce(e->>'recurring_id', '') <> '' THEN ' (evento recorrente)' ELSE '' END || '. Aceitar ou recusar?';
    res := res || jsonb_build_array(jsonb_build_object('chat_id', u.telegram_id, 'text', t, 'rid', pid));
    cnt := cnt + 1;
  END LOOP;
  RETURN res;
EXCEPTION WHEN others THEN
  RETURN '[]'::jsonb;
END $$;

-- ---------------------------------------------------------------- preferencias (com expediente)
CREATE OR REPLACE FUNCTION f_set_prefs(p_user bigint, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'agente', 'public'
AS $function$
DECLARE
  t text := ''; v text; tm time; n integer; ws time; we time; u users%ROWTYPE;
BEGIN
  IF nullif(p->>'lead', '') IS NOT NULL THEN
    UPDATE users SET default_lead_minutes = (p->>'lead')::int WHERE id = p_user;
    t := t || E'\nAviso padrão: ' || (p->>'lead') || ' min antes dos compromissos.';
  END IF;
  IF nullif(p->>'supply_days', '') IS NOT NULL THEN
    UPDATE users SET supply_alert_days = (p->>'supply_days')::int WHERE id = p_user;
    t := t || E'\nAviso de estoque: ' || (p->>'supply_days') || ' dia(s) antes de acabar.';
  END IF;
  v := nullif(btrim(coalesce(p->>'summary', '')), '');
  IF v IS NOT NULL THEN
    IF lower(v) IN ('off', 'desligar') THEN UPDATE users SET morning_enabled = false WHERE id = p_user; t := t || E'\nDesliguei o resumo da manhã.';
    ELSIF lower(v) = 'on' THEN UPDATE users SET morning_enabled = true WHERE id = p_user; t := t || E'\nLiguei o resumo da manhã.';
    ELSE BEGIN tm := v::time; UPDATE users SET summary_time = tm, morning_enabled = true WHERE id = p_user; t := t || E'\nResumo da manhã às ' || to_char(tm, 'HH24:MI') || '.';
      EXCEPTION WHEN others THEN t := t || E'\nNão entendi o horário "' || v || '" do resumo da manhã.'; END;
    END IF;
  END IF;
  v := nullif(btrim(coalesce(p->>'evening', '')), '');
  IF v IS NOT NULL THEN
    IF lower(v) = 'off' THEN UPDATE users SET evening_enabled = false WHERE id = p_user; t := t || E'\nDesliguei o resumo do fim do dia.';
    ELSIF lower(v) = 'on' THEN UPDATE users SET evening_enabled = true WHERE id = p_user; t := t || E'\nLiguei o resumo do fim do dia.';
    ELSE BEGIN tm := v::time; UPDATE users SET evening_time = tm, evening_enabled = true WHERE id = p_user; t := t || E'\nResumo do fim do dia às ' || to_char(tm, 'HH24:MI') || '.';
      EXCEPTION WHEN others THEN t := t || E'\nNão entendi o horário "' || v || '" do resumo do fim do dia.'; END;
    END IF;
  END IF;
  IF nullif(btrim(coalesce(p->>'nickname', '')), '') IS NOT NULL THEN
    UPDATE users SET nickname = left(btrim(p->>'nickname'), 30) WHERE id = p_user;
    t := t || E'\nDaqui pra frente te chamo de ' || left(btrim(p->>'nickname'), 30) || '.';
  END IF;
  IF nullif(p->>'no_emoji', '') IS NOT NULL THEN
    UPDATE users SET no_emoji = (p->>'no_emoji')::boolean WHERE id = p_user;
    t := t || CASE WHEN (p->>'no_emoji')::boolean THEN E'\nPronto, sem emoji.' ELSE E'\nCerto, posso usar emoji de novo.' END;
  END IF;
  v := nullif(btrim(coalesce(p->>'timezone', '')), '');
  IF v IS NOT NULL THEN
    SELECT count(*) INTO n FROM pg_timezone_names WHERE name = v;
    IF n = 1 THEN UPDATE users SET timezone = v WHERE id = p_user; t := t || E'\nFuso ajustado para ' || v || '. Lembretes já marcados continuam no horário absoluto.';
    ELSE t := t || E'\nNão reconheci o fuso "' || v || '". Diga a cidade, ex.: Lisboa.'; END IF;
  END IF;
  -- expediente (usado na busca de horario livre)
  IF nullif(btrim(coalesce(p->>'work_start', '')), '') IS NOT NULL OR nullif(btrim(coalesce(p->>'work_end', '')), '') IS NOT NULL THEN
    SELECT * INTO u FROM users WHERE id = p_user;
    ws := u.work_start; we := u.work_end;
    BEGIN
      IF nullif(btrim(coalesce(p->>'work_start', '')), '') IS NOT NULL THEN ws := btrim(p->>'work_start')::time; END IF;
      IF nullif(btrim(coalesce(p->>'work_end', '')), '') IS NOT NULL THEN we := btrim(p->>'work_end')::time; END IF;
      IF we <= ws THEN
        t := t || E'\nO fim do expediente precisa ser depois do início.';
      ELSE
        UPDATE users SET work_start = ws, work_end = we WHERE id = p_user;
        t := t || E'\nExpediente: ' || to_char(ws, 'HH24:MI') || ' às ' || to_char(we, 'HH24:MI') || ' (uso para achar horário livre).';
      END IF;
    EXCEPTION WHEN others THEN t := t || E'\nNão entendi o horário do expediente.'; END;
  END IF;
  IF t = '' THEN t := E'\nNão achei nada para mudar.'; END IF;
  RETURN jsonb_build_object('text', 'Pronto:' || t);
END $function$;

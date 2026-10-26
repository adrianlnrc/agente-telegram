-- Contatos, grupos e favoritos para convidar pessoas em compromissos.
SET search_path = agente;

CREATE TABLE IF NOT EXISTS contacts (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  email      text NOT NULL,
  favorite   boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, name)
);

CREATE TABLE IF NOT EXISTS contact_groups (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  UNIQUE (user_id, name)
);

CREATE TABLE IF NOT EXISTS contact_group_members (
  group_id   bigint NOT NULL REFERENCES contact_groups(id) ON DELETE CASCADE,
  contact_id bigint NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, contact_id)
);

-- Salva ou atualiza um contato (nome -> e-mail).
CREATE OR REPLACE FUNCTION f_contact_save(p_user bigint, p_name text, p_email text, p_favorite boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c contacts%ROWTYPE;
BEGIN
  IF p_email !~ '^[^@ ]+@[^@ ]+\.[^@ ]+$' THEN RETURN jsonb_build_object('ok', false, 'error', 'email'); END IF;
  INSERT INTO contacts(user_id, name, email, favorite)
  VALUES (p_user, lower(trim(p_name)), lower(trim(p_email)), COALESCE(p_favorite, false))
  ON CONFLICT (user_id, name) DO UPDATE SET email = EXCLUDED.email, favorite = COALESCE(p_favorite, contacts.favorite)
  RETURNING * INTO c;
  RETURN jsonb_build_object('ok', true, 'name', c.name, 'email', c.email, 'favorite', c.favorite);
END $$;

-- Cria ou substitui um grupo a partir de uma lista de nomes de contatos.
CREATE OR REPLACE FUNCTION f_group_save(p_user bigint, p_group text, p_names text[])
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE g bigint; n text; cid bigint; missing text[] := '{}'; added text[] := '{}';
BEGIN
  INSERT INTO contact_groups(user_id, name) VALUES (p_user, lower(trim(p_group)))
  ON CONFLICT (user_id, name) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO g;
  DELETE FROM contact_group_members WHERE group_id = g;
  FOREACH n IN ARRAY COALESCE(p_names, '{}') LOOP
    SELECT id INTO cid FROM contacts WHERE user_id = p_user AND name = lower(trim(n));
    IF cid IS NULL THEN missing := missing || lower(trim(n));
    ELSE INSERT INTO contact_group_members VALUES (g, cid) ON CONFLICT DO NOTHING; added := added || lower(trim(n)); END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'group', lower(trim(p_group)), 'members', to_jsonb(added), 'missing', to_jsonb(missing));
END $$;

-- Resolve nomes e grupos citados num convite em e-mails. Nomes sem cadastro voltam em "unknown".
CREATE OR REPLACE FUNCTION f_resolve_invitees(p_user bigint, p_names text[])
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE n text; found jsonb := '[]'; unknown text[] := '{}'; g bigint;
BEGIN
  FOREACH n IN ARRAY COALESCE(p_names, '{}') LOOP
    n := lower(trim(n));
    SELECT id INTO g FROM contact_groups WHERE user_id = p_user AND name = n;
    IF g IS NOT NULL THEN
      found := found || COALESCE((SELECT jsonb_agg(jsonb_build_object('name', c.name, 'email', c.email))
        FROM contact_group_members m JOIN contacts c ON c.id = m.contact_id WHERE m.group_id = g), '[]'::jsonb);
    ELSIF EXISTS (SELECT 1 FROM contacts WHERE user_id = p_user AND name = n) THEN
      found := found || (SELECT jsonb_build_array(jsonb_build_object('name', name, 'email', email)) FROM contacts WHERE user_id = p_user AND name = n);
    ELSIF n ~ '^[^@ ]+@[^@ ]+\.[^@ ]+$' THEN
      found := found || jsonb_build_array(jsonb_build_object('name', n, 'email', n));
    ELSE unknown := unknown || n; END IF;
  END LOOP;
  RETURN jsonb_build_object('invitees', found, 'unknown', to_jsonb(unknown));
END $$;

-- Lista contatos (favoritos primeiro) e grupos, para /contatos e para os botoes de favoritos.
CREATE OR REPLACE FUNCTION f_contacts_list(p_user bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'contacts', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', name, 'email', email, 'favorite', favorite) ORDER BY favorite DESC, name)
                          FROM contacts WHERE user_id = p_user), '[]'::jsonb),
    'groups', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', g.name,
                          'members', (SELECT COALESCE(jsonb_agg(c.name ORDER BY c.name), '[]'::jsonb) FROM contact_group_members m JOIN contacts c ON c.id = m.contact_id WHERE m.group_id = g.id)) ORDER BY g.name)
                        FROM contact_groups g WHERE g.user_id = p_user), '[]'::jsonb));
$$;

DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'agente' AND p.proname IN ('f_contact_save','f_group_save','f_resolve_invitees','f_contacts_list') LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = agente, public', f.sig);
  END LOOP;
END $$;

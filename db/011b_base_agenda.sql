-- Base comum da agenda e dos botoes novos (fase 2/3): tabela de acoes pendentes e despachante de callbacks.
SET search_path TO agente, public;

CREATE TABLE IF NOT EXISTS agenda_pending (
  id           bigserial PRIMARY KEY,
  user_id      bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind         text NOT NULL CHECK (kind IN ('move','cancel','create','respond')),
  calendar_key text NOT NULL DEFAULT '',
  grp          uuid,
  event_id     text,
  title        text NOT NULL DEFAULT '',
  old_start    timestamptz,
  old_end      timestamptz,
  new_start    timestamptz,
  new_end      timestamptz,
  payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
  state        text NOT NULL DEFAULT 'open' CHECK (state IN ('open','done','cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS agenda_pending_user ON agenda_pending (user_id, state);

-- f_callback vira despachante: prefixos novos vao para os modulos; o resto continua na funcao antiga.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'agente'::regnamespace AND proname = 'f_callback_base') THEN
    ALTER FUNCTION f_callback(bigint, text) RENAME TO f_callback_base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION f_callback(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE a text := split_part(p_data, ':', 1);
BEGIN
  IF a LIKE 'ag%' THEN RETURN f_agenda_cb(p_user, p_data);      -- agenda (agok, agno, agpk, agsc, agfy, agfo, agrs, agrn)
  ELSIF a LIKE 'ct%' THEN RETURN f_contacts_cb(p_user, p_data);  -- contatos e convites (fase 3)
  ELSIF a LIKE 'ex%' THEN RETURN f_extras_cb(p_user, p_data);    -- extras (cartoes, lembretes recorrentes)
  END IF;
  RETURN f_callback_base(p_user, p_data);
END $$;

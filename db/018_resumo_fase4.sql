-- Fase 4: projetos e faturas de cartao entram no resumo (manha e noite).
-- f_summary_data original vira f_summary_data_base; o novo f_summary_data
-- devolve o mesmo JSON mais o campo extras_text (texto pronto, pode ser vazio).
DO $$
BEGIN
  IF to_regproc('agente.f_summary_data_base') IS NULL THEN
    ALTER FUNCTION agente.f_summary_data(bigint) RENAME TO f_summary_data_base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION agente.f_summary_data(p_user bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'agente', 'public'
AS $function$
DECLARE
  v jsonb; c jsonb; pj text; t text := ''; x jsonb; NL text := chr(10);
BEGIN
  v := f_summary_data_base(p_user);
  c := COALESCE(v->'cards', '[]'::jsonb);
  FOR x IN SELECT * FROM jsonb_array_elements(c) LOOP
    t := t || '- Fatura ' || (x->>'name') || ' R$ ' || replace(to_char((x->>'amount')::numeric, 'FM999G990D00'), ',', '.') || ' vence ' || (x->>'due')
         || CASE WHEN (x->>'days')::int = 0 THEN ' (hoje)' WHEN (x->>'days')::int = 1 THEN ' (amanha)' ELSE '' END || NL;
  END LOOP;
  IF t <> '' THEN t := 'Cartoes:' || NL || t; END IF;
  pj := COALESCE(f_projects_summary(p_user)->>'text', '');
  IF pj <> '' THEN t := t || CASE WHEN t <> '' THEN NL ELSE '' END || pj; END IF;
  RETURN v || jsonb_build_object('extras_text', rtrim(t, NL));
END $function$;

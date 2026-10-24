-- As funcoes precisam enxergar as tabelas do schema agente quando chamadas de fora (n8n).
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'agente' LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = agente, public', f.sig);
  END LOOP;
END $$;
ALTER DATABASE "AgenteTelegram" SET search_path = agente, public;

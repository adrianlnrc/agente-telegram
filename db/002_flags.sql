-- Marcadores para nao repetir envios.
SET search_path = agente;
ALTER TABLE users    ADD COLUMN IF NOT EXISTS last_summary_on    date;
ALTER TABLE supplies ADD COLUMN IF NOT EXISTS alert_notified_on  date;
-- supplies_status deve expor as novas colunas (s.*), entao recria a view.
DROP VIEW IF EXISTS supplies_status;
CREATE VIEW supplies_status AS
SELECT s.*,
       GREATEST(0, s.units_total - ((CURRENT_DATE - s.started_on) - s.paused_days) * s.units_per_day) AS units_left,
       s.started_on + s.paused_days + CEIL(s.units_total / s.units_per_day)::int                   AS runs_out_on,
       s.started_on + s.paused_days + CEIL(s.units_total / s.units_per_day)::int - s.alert_days    AS alert_on
FROM supplies s;

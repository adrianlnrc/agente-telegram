-- Corrige "tenho 12 na cartela" depois de "tomei": a dose de hoje (ja tomada)
-- era descontada de novo porque started_on = hoje. Se ja houve dose tomada hoje,
-- a contagem recomeca amanha.
SET search_path TO agente, public;

CREATE OR REPLACE FUNCTION f_supply_adjust(p_user bigint, p_item text, p_units_left integer, p_pause_days integer)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'agente', 'public' AS $$
DECLARE v_id bigint; v_start date;
BEGIN
  v_id := f_find_supply(p_user, p_item);
  IF v_id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;
  IF p_units_left IS NOT NULL THEN
    v_start := CURRENT_DATE;
    IF EXISTS (SELECT 1 FROM supplies s JOIN supply_doses d ON d.supply_id = s.id
               WHERE s.id = v_id AND s.take_time IS NOT NULL
                 AND d.status = 'taken' AND d.dose_date = CURRENT_DATE) THEN
      v_start := CURRENT_DATE + 1;
    END IF;
    UPDATE supplies SET units_total = p_units_left, pack_size = COALESCE(pack_size, p_units_left),
      started_on = v_start, paused_days = 0, alert_notified_on = NULL WHERE id = v_id;
  END IF;
  IF COALESCE(p_pause_days, 0) > 0 THEN
    UPDATE supplies SET paused_days = paused_days + p_pause_days, alert_notified_on = NULL WHERE id = v_id;
  END IF;
  RETURN (SELECT jsonb_build_object('found', true, 'item', item, 'units_left', units_left,
            'runs_out_on', to_char(runs_out_on, 'DD/MM'), 'alert_on', to_char(alert_on, 'DD/MM'))
          FROM supplies_status WHERE id = v_id);
END $$;

-- AgeCare — Hito 2: alertas accionables de la cuidadora
-- 930_alert_type_incident.sql — Nuevo tipo de alerta 'incident'
--
-- Problema que resuelve (DEF-003):
--   Un incidente grave o critico que reporta la cuidadora (una caida, una
--   reaccion adversa a un medicamento, que costo despertar al paciente) NO
--   generaba ninguna alerta para la red de apoyo. Peor: la columna de
--   incidents.severity = 'critical' estaba bloqueada en la aplicacion porque
--   el constraint ck_incidents_critical_has_alert exige una alerta asociada,
--   y las alertas no tenian un tipo que representara un incidente.
--
--   alerts.type y notification_settings.alert_type compartian la misma lista
--   cerrada de 5 valores. Se agrega 'incident' a ambas para que un incidente
--   grave/critico pueda materializar una alerta real, enlazada por
--   incidents.alert_id, y para que el familiar pueda activar o silenciar ese
--   tipo de aviso como cualquier otro (no es critico-bloqueado: la caida y el
--   SOS siguen siendo los unicos que no se pueden apagar).

ALTER TABLE alerts DROP CONSTRAINT IF EXISTS ck_alerts_type;
ALTER TABLE alerts ADD CONSTRAINT ck_alerts_type CHECK (
    type IN ('fall', 'vital_out_of_range', 'missed_dose', 'sos',
             'wearable_offline', 'incident')
);

ALTER TABLE notification_settings DROP CONSTRAINT IF EXISTS ck_notification_settings_type;
ALTER TABLE notification_settings ADD CONSTRAINT ck_notification_settings_type CHECK (
    alert_type IN ('fall', 'vital_out_of_range', 'missed_dose', 'sos',
                   'wearable_offline', 'incident')
);

COMMENT ON COLUMN alerts.type IS
    'Tipo de alerta. fall | vital_out_of_range | missed_dose | sos | wearable_offline | incident. ''incident'' la genera un incidente grave o critico reportado en la bitacora (DEF-003).';

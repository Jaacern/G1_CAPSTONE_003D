-- Revierte 963_avisos_de_alertas.sql
--
-- PIERDE DATOS: se olvida a que alertas ya se aviso y cuantas veces. El
-- repartidor vuelve a tratarlas como no avisadas, asi que al revertir con
-- alertas activas se va a volver a avisar de ellas una vez.

DROP INDEX IF EXISTS ix_alert_deliveries_queued;
ALTER TABLE alert_deliveries DROP CONSTRAINT IF EXISTS ck_alert_deliveries_round;
ALTER TABLE alert_deliveries DROP COLUMN IF EXISTS notice_round;

DROP INDEX IF EXISTS ix_alerts_sin_avisar;
ALTER TABLE alerts DROP CONSTRAINT IF EXISTS ck_alerts_escalated_after_notice;
ALTER TABLE alerts DROP CONSTRAINT IF EXISTS ck_alerts_renotify_count;
ALTER TABLE alerts DROP COLUMN IF EXISTS renotify_count;
ALTER TABLE alerts DROP COLUMN IF EXISTS notified_at;

DELETE FROM system_parameters WHERE key = 'alert_renotify_max';

-- La descripcion del otro parametro vuelve a lo que decia antes de RF-52.
UPDATE system_parameters
   SET description = 'Minutos sin atencion tras los cuales se escala una alerta critica al siguiente contacto.'
 WHERE key = 'alert_escalation_minutes';

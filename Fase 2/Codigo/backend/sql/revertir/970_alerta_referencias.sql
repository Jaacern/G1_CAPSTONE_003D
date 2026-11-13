-- Revierte 970_alerta_referencias.sql
--
-- PIERDE las columnas alerts.dose_id y alerts.reading_id. No pierde
-- informacion de verdad: esas referencias siguen estando en alerts.payload
-- ('dose_id' / 'reading_id'), que esta migracion nunca borro. El codigo que
-- acompana a 970 debe revertirse junto con esto (vuelve a leer del payload).

DROP INDEX IF EXISTS ux_alerts_dose;
DROP INDEX IF EXISTS ux_alerts_reading;

ALTER TABLE alerts DROP CONSTRAINT IF EXISTS fk_alerts_dose;
ALTER TABLE alerts DROP COLUMN IF EXISTS dose_id;
ALTER TABLE alerts DROP COLUMN IF EXISTS reading_id;

-- Restaurar el comentario original del payload.
COMMENT ON COLUMN alerts.payload IS
    'Datos que originaron la alerta (lectura fuera de rango, dosis omitida, etc.). Se mantiene como jsonb de forma INTENCIONAL: la estructura varía según el tipo de alerta (patrón de atributos variables). Normalizarlo exigiría una tabla de detalle por cada tipo, lo que no aporta integridad porque estos datos no se consultan ni se cruzan: solo se muestran al abrir la alerta. Excepción documentada a 1FN.';

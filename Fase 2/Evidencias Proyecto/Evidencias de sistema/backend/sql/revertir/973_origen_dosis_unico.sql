-- Revierte 973_origen_dosis_unico.sql.
--
-- Afloja ck_scheduled_doses_origen de "exactamente uno" de vuelta a "al menos
-- uno", que es lo que habia antes: vuelve a permitir que una dosis conviva con
-- medication_id y treatment_item_id a la vez.
--
-- El medication_id que 973 anulo en las dosis de doble origen NO se reconstruye
-- aqui: no quedo guardado en ningun lado, y esas filas conservan su
-- treatment_item_id, que es un origen valido bajo el CHECK aflojado. Revertir
-- solo reabre la posibilidad del doble origen hacia adelante; no reescribe el
-- historial ya consolidado.

ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_origen;
ALTER TABLE scheduled_doses
    ADD CONSTRAINT ck_scheduled_doses_origen
        CHECK (medication_id IS NOT NULL OR treatment_item_id IS NOT NULL);

COMMENT ON COLUMN scheduled_doses.treatment_item_id IS
    'Indicación de la que nace la dosis. Reemplaza a medication_id en el modelo de tratamientos; conviven durante la transición (ck_scheduled_doses_origen exige al menos uno).';

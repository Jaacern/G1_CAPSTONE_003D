-- Revierte 973_origen_dosis_unico.sql.
--
-- Afloja ck_scheduled_doses_origen de "exactamente uno" de vuelta a "al menos
-- uno", que es lo que habia antes: vuelve a permitir que una dosis conviva con
-- medication_id y treatment_item_id a la vez.
--
-- La consolidacion de DATOS que hizo 973 NO se deshace aqui, a proposito:
--   · el medication_id anulado en las dosis de doble origen no se puede
--     reconstruir (no quedo guardado en ningun lado), y
--   · la fecha de discontinuado de los medicamentos migrados no se distingue
--     de una baja legitima, asi que reactivarlos a ciegas corromperia datos.
-- Las filas quedan con un unico origen, que sigue siendo valido bajo el CHECK
-- aflojado. Revertir solo reabre la posibilidad del doble origen hacia
-- adelante; no reescribe el historial ya consolidado.

ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_origen;
ALTER TABLE scheduled_doses
    ADD CONSTRAINT ck_scheduled_doses_origen
        CHECK (medication_id IS NOT NULL OR treatment_item_id IS NOT NULL);

COMMENT ON COLUMN scheduled_doses.treatment_item_id IS
    'Indicación de la que nace la dosis. Reemplaza a medication_id en el modelo de tratamientos; conviven durante la transición (ck_scheduled_doses_origen exige al menos uno).';

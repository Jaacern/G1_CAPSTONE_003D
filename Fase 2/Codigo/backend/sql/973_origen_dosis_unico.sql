-- MIGRACION IDEMPOTENTE
-- Consolida el origen de cada dosis: exactamente una indicacion (hallazgo 3).
--
-- EL PROBLEMA
--   scheduled_doses puede nacer de un medicamento (medication_id) o de un item
--   de tratamiento (treatment_item_id). 960_migrate_treatments.sql, al migrar
--   el plan viejo, ato las dosis futuras a su treatment_item pero dejo el
--   medication_id puesto: quedaron dosis con DOS origenes a la vez. Ademas los
--   medicamentos migrados siguieron marcados activos (discontinued_at NULL)
--   aunque el generador ya no los usa -defiere al tratamiento vigente-. El
--   CHECK ck_scheduled_doses_origen solo exigia "al menos uno", asi que nada
--   impedia el doble origen ni la duda de cual es la indicacion real.
--
-- EL ARREGLO
--   El modelo de tratamientos es el oficial (lo fija 306). Se completa la
--   transicion que 960 dejo a medio camino:
--     1. En las dosis con doble origen se anula medication_id y se conserva
--        treatment_item_id: la indicacion real es el item del tratamiento.
--     2. Se discontinuan los medicamentos cuyos pacientes ya tienen tratamiento
--        vigente (los que 960 migro). No cambia el comportamiento -el generador
--        ya no generaba desde ellos por su propio guard- pero deja el dato
--        honesto: un medicamento "activo" que no genera nada confunde.
--     3. ck_scheduled_doses_origen pasa de "al menos uno" a "exactamente uno",
--        para que ninguna dosis nueva pueda volver a nacer con doble origen.
--
--   Idempotente: en una segunda corrida los UPDATE no encuentran filas y el
--   CHECK se recrea con DROP ... IF EXISTS. Las dosis historicas atadas solo a
--   medication_id (modelo viejo) se respetan: siguen teniendo un unico origen.

-- 1. Dosis con doble origen -> se quedan con el item (indicacion real).
UPDATE scheduled_doses
   SET medication_id = NULL
 WHERE medication_id     IS NOT NULL
   AND treatment_item_id IS NOT NULL;

-- 2. Medicamentos ya migrados: su paciente tiene tratamiento vigente y el
--    generador los ignora. Se marcan discontinuados para que el dato refleje
--    la realidad.
UPDATE medications m
   SET discontinued_at = now()
 WHERE m.discontinued_at IS NULL
   AND EXISTS (SELECT 1 FROM treatments tr
                WHERE tr.patient_id = m.patient_id
                  AND tr.status = 'vigente');

-- 3. Antes de endurecer el CHECK, confirmar que no queda ninguna dosis con
--    doble origen ni sin origen. Si quedara, la migracion se detiene sin tocar
--    el CHECK y sin dejar nada a medias (cada archivo corre en su transaccion).
DO $$
DECLARE
    dobles    bigint;
    huerfanas bigint;
BEGIN
    SELECT count(*) INTO dobles
      FROM scheduled_doses
     WHERE medication_id IS NOT NULL AND treatment_item_id IS NOT NULL;
    IF dobles > 0 THEN
        RAISE EXCEPTION 'Quedan % dosis con doble origen; no se endurece el CHECK.', dobles;
    END IF;

    SELECT count(*) INTO huerfanas
      FROM scheduled_doses
     WHERE medication_id IS NULL AND treatment_item_id IS NULL;
    IF huerfanas > 0 THEN
        RAISE EXCEPTION 'Quedan % dosis sin ningun origen; revisar antes de continuar.', huerfanas;
    END IF;
END $$;

-- 4. Exactamente un origen por dosis.
ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_origen;
ALTER TABLE scheduled_doses
    ADD CONSTRAINT ck_scheduled_doses_origen
        CHECK (num_nonnulls(medication_id, treatment_item_id) = 1);

COMMENT ON COLUMN scheduled_doses.treatment_item_id IS
    'Indicacion de la que nace la dosis en el modelo de tratamientos (el oficial). Una dosis tiene EXACTAMENTE un origen: treatment_item_id en el modelo vigente, o medication_id en las dosis historicas del modelo viejo, nunca los dos (ck_scheduled_doses_origen).';

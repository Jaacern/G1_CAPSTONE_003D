-- AgeCare — Transición al modelo de tratamientos
-- 960_migrate_treatments.sql — Agrupa el plan actual (medications) en un
--                              tratamiento vigente por paciente.
--
-- Corre DESPUÉS del seed. Es idempotente: solo actúa sobre pacientes que tienen
-- medicación activa y que todavía NO tienen un tratamiento vigente. Así puede
-- re-ejecutarse sin duplicar.
--
-- Qué hace, por paciente con medications activas (discontinued_at IS NULL):
--   1. Crea un treatment 'vigente'. prescribed_by = el prescriptor del primer
--      medicamento si existe; si no, el familiar owner (tratamiento de arranque).
--   2. Crea un treatment_item por cada medicamento activo, copiando dosis,
--      instrucciones, grace y horarios/días (action='kept', es el punto de
--      partida: no hay versión anterior).
--   3. Enlaza las dosis futuras (scheduled_doses de hoy en adelante) de esos
--      medicamentos a su treatment_item, para que el historial y el generador
--      queden consistentes. Las dosis pasadas se dejan atadas a medication_id:
--      son hechos ya ocurridos, no se reescriben.

DO $$
DECLARE
    p           record;
    t_id        uuid;
    m           record;
    item_id     uuid;
    prescriptor uuid;
BEGIN
    FOR p IN
        SELECT DISTINCT med.patient_id
          FROM medications med
         WHERE med.discontinued_at IS NULL
           AND NOT EXISTS (
                 SELECT 1 FROM treatments t
                  WHERE t.patient_id = med.patient_id
                    AND t.status = 'vigente')
    LOOP
        -- Prescriptor: el del primer medicamento con prescribed_by; si ninguno
        -- tiene, el familiar owner del paciente.
        SELECT prescribed_by INTO prescriptor
          FROM medications
         WHERE patient_id = p.patient_id
           AND discontinued_at IS NULL
           AND prescribed_by IS NOT NULL
         ORDER BY created_at
         LIMIT 1;

        IF prescriptor IS NULL THEN
            SELECT user_id INTO prescriptor
              FROM patient_members
             WHERE patient_id = p.patient_id
               AND is_owner
               AND removed_at IS NULL
             LIMIT 1;
        END IF;

        -- Si no hay ni prescriptor ni owner (dato inconsistente), se omite.
        IF prescriptor IS NULL THEN
            CONTINUE;
        END IF;

        INSERT INTO treatments (patient_id, status, prescribed_by, prescriber_role, note)
        VALUES (p.patient_id, 'vigente', prescriptor, 'doctor',
                'Tratamiento inicial migrado del plan de medicamentos existente.')
        RETURNING id INTO t_id;

        FOR m IN
            SELECT id, name, dose_amount, dose_unit, instructions, grace_window_min
              FROM medications
             WHERE patient_id = p.patient_id
               AND discontinued_at IS NULL
        LOOP
            INSERT INTO treatment_items
                (treatment_id, name, dose_amount, dose_unit, instructions,
                 grace_window_min, action)
            VALUES
                (t_id, m.name, m.dose_amount, m.dose_unit, m.instructions,
                 m.grace_window_min, 'kept')
            RETURNING id INTO item_id;

            -- Horarios y días, copiados del medicamento.
            INSERT INTO treatment_item_times (treatment_item_id, time_of_day)
            SELECT item_id, time_of_day
              FROM medication_times WHERE medication_id = m.id
            ON CONFLICT (treatment_item_id, time_of_day) DO NOTHING;

            INSERT INTO treatment_item_days (treatment_item_id, day_of_week)
            SELECT item_id, day_of_week
              FROM medication_days WHERE medication_id = m.id
            ON CONFLICT (treatment_item_id, day_of_week) DO NOTHING;

            -- Dosis futuras de este medicamento quedan atadas al item.
            UPDATE scheduled_doses
               SET treatment_item_id = item_id
             WHERE medication_id = m.id
               AND treatment_item_id IS NULL
               AND scheduled_at >= date_trunc('day', now());
        END LOOP;

        RAISE NOTICE 'Tratamiento migrado para paciente %', p.patient_id;
    END LOOP;
END $$;

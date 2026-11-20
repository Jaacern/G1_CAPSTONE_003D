-- AgeCare — Bloque 3: Medicación
-- 308_treatment_specialty.sql — Tratamientos por especialidad (varios vigentes)
--
-- POR QUÉ (apunte del cliente)
--   Un paciente puede estar bajo varios médicos a la vez: la cardióloga (Ana)
--   lleva un tratamiento y el traumatólogo otro, cada uno con su propio
--   historial de cambios de dosis. El modelo del Hito 3 asumía UN solo
--   tratamiento vigente por paciente; eso no refleja la realidad clínica.
--
--   Solución: el tratamiento pertenece a una ESPECIALIDAD. Pueden coexistir
--   varios vigentes (uno por especialidad). La restricción "un vigente por
--   paciente" pasa a ser "un vigente por paciente y especialidad". Cada
--   especialidad versiona su propio historial por separado (supersedes_id ya
--   encadena dentro de la misma especialidad).

ALTER TABLE treatments
    ADD COLUMN IF NOT EXISTS specialty varchar(40) NOT NULL DEFAULT 'general';

COMMENT ON COLUMN treatments.specialty IS
    'Especialidad que define el tratamiento (general, cardiologia, traumatologia, ...). Permite varios tratamientos vigentes en paralelo, uno por especialidad, cada uno con su propio historial.';

-- Duración del tratamiento: hasta cuándo está previsto. NULL = permanente
-- (crónico, p. ej. hipertensión). Con fecha = temporal (p. ej. antibiótico
-- 7 días, analgésico post-fractura). Es una previsión clínica, distinta de
-- effective_to, que marca cuándo fue REEMPLAZADO por una versión nueva.
ALTER TABLE treatments
    ADD COLUMN IF NOT EXISTS review_date date;

COMMENT ON COLUMN treatments.review_date IS
    'Fecha prevista de término o revisión del tratamiento. NULL = permanente/crónico. No es effective_to (eso es el reemplazo por versión).';

-- El índice único de "un solo vigente por paciente" se reemplaza por uno que
-- admite un vigente por paciente Y especialidad.
DROP INDEX IF EXISTS ux_treatments_vigente;
CREATE UNIQUE INDEX ux_treatments_vigente_especialidad
    ON treatments (patient_id, specialty) WHERE status = 'vigente';

-- Historial: por paciente y especialidad, lo más reciente primero.
CREATE INDEX IF NOT EXISTS ix_treatments_patient_specialty
    ON treatments (patient_id, specialty, effective_from DESC);

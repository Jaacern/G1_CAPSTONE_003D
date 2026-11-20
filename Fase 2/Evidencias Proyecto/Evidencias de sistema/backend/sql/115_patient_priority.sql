-- AgeCare — Bloque 1: Identidad y acceso
-- 115_patient_priority.sql — Prioridad de atención del paciente (Fase 6)
--
-- POR QUÉ (decisión del usuario, docs/DECISIONES_ABIERTAS_FICHA.md punto 2)
--   Complejidad y prioridad NO son lo mismo:
--     · complexity (ya existe, 113): carga clínica del paciente. Un crónico con
--       varias patologías = alta complejidad. Es estable.
--     · priority (esta migración): urgencia de atención / vigilancia AHORA.
--   Un paciente puede ser crónico de ALTA complejidad pero BAJA prioridad si está
--   controlado, al día con su tratamiento y con signos vitales normales. Su carga
--   clínica no cambió (sigue alta complejidad), pero no requiere atención urgente.
--
--   Por eso son dos columnas separadas, no una sola. priority es más volátil
--   (puede cambiar con el estado del paciente); complexity es más estable.

ALTER TABLE patients
    ADD COLUMN IF NOT EXISTS priority varchar(10);

ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_priority;
ALTER TABLE patients ADD CONSTRAINT ck_patients_priority CHECK (
    priority IS NULL OR priority IN ('baja', 'media', 'alta')
);

COMMENT ON COLUMN patients.priority IS
    'Prioridad de atención/vigilancia del paciente: baja | media | alta. Distinta de complexity (carga clínica): un alta complejidad controlado puede ser baja prioridad. NULL = no evaluada.';

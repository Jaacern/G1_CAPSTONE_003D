-- AgeCare — Ajuste de compatibilidad
-- 922_care_tasks_categoria.sql — La tarea de cuidado necesita su categoria
--
-- La pantalla de tarea ofrece una categoria de una lista de seis y la manda al
-- crear, y la tarjeta de la tarea la muestra. care_tasks no tiene esa columna,
-- asi que la categoria se perdia en el camino: se elegia, se enviaba, y la
-- tarea volvia sin ella.
--
-- La lista es cerrada por el mismo motivo que en care_observations. La pantalla
-- de informes cuenta tareas por tipo, y con texto libre 'Medicación',
-- 'medicacion' y 'Medicamentos' serian tres categorias distintas.

ALTER TABLE care_tasks ADD COLUMN IF NOT EXISTS category varchar(20);

ALTER TABLE care_tasks DROP CONSTRAINT IF EXISTS ck_care_tasks_category;

ALTER TABLE care_tasks ADD CONSTRAINT ck_care_tasks_category CHECK (
    category IS NULL OR category IN (
        'hygiene', 'medication', 'food', 'activity', 'company', 'other'
    )
);

-- La pantalla de tareas del dia filtra por paciente, fecha y estado. El indice
-- deja fuera las borradas, que es justo lo que la consulta nunca pide.
CREATE INDEX IF NOT EXISTS ix_care_tasks_patient_fecha
    ON care_tasks (patient_id, due_date DESC, due_time)
    WHERE deleted_at IS NULL;

COMMENT ON COLUMN care_tasks.category IS
    'Tipo de tarea, lista cerrada, opcional. Permite contar tareas por tipo en los informes de la cuidadora.';

-- AgeCare — Bloque 3: Medicación
-- 306_treatments.sql — Tratamientos e indicaciones con vigencia y versionado
--
-- POR QUÉ (DEF-007, DEF-008, apuntes del cliente)
--   Hasta ahora un medicamento era una fila suelta en `medications` y cambiar
--   la dosis hacía UPDATE sobre esa fila: se perdía lo anterior. No había forma
--   de responder "¿con qué dosis partió en enero y cómo evolucionó?".
--
--   Un TRATAMIENTO es el conjunto de indicaciones vigentes que el médico define
--   en un momento dado. Cambiar el esquema NO edita en el lugar: cierra el
--   tratamiento vigente y crea uno nuevo, versionando cada indicación. Así
--   "losartán 50 → 100 → 80" queda como historial consultable.
--
--   Receta (documento formal, medical_documents) ≠ indicación (orden ejecutable
--   que vive aquí). treatment_documents las vincula sin confundirlas (DEF-014).
--
--   Durante la transición conviven con `medications`: 307_migrate_medications.sql
--   agrupa el plan actual en un tratamiento vigente y la app migra después.

-- ─────────────────────────────────────────────────────────────────
-- treatments — el esquema farmacológico vigente (o histórico) de un paciente
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE treatments (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid        NOT NULL,
    status          varchar(12) NOT NULL DEFAULT 'vigente',
    -- Quién lo definió. Decisión confirmada: SOLO el médico define tratamiento.
    prescribed_by   uuid        NOT NULL,
    prescriber_role varchar(10) NOT NULL DEFAULT 'doctor',
    effective_from  timestamptz NOT NULL DEFAULT now(),
    effective_to    timestamptz,
    -- Cadena histórica: este tratamiento reemplazó a supersedes_id.
    supersedes_id   uuid,
    note            varchar(500),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_treatments_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_treatments_prescriber
        FOREIGN KEY (prescribed_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_treatments_supersedes
        FOREIGN KEY (supersedes_id) REFERENCES treatments(id) ON DELETE RESTRICT,
    CONSTRAINT ck_treatments_status
        CHECK (status IN ('vigente', 'superseded', 'cancelled')),
    CONSTRAINT ck_treatments_role
        CHECK (prescriber_role IN ('doctor', 'caregiver')),
    -- Un tratamiento vigente tiene effective_to NULL; uno cerrado lo tiene puesto.
    CONSTRAINT ck_treatments_vigente_abierto
        CHECK (status <> 'vigente' OR effective_to IS NULL),
    CONSTRAINT ck_treatments_cerrado_fechado
        CHECK (status = 'vigente' OR effective_to IS NOT NULL),
    CONSTRAINT ck_treatments_rango
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

-- Un SOLO tratamiento vigente por paciente. El índice parcial lo garantiza.
CREATE UNIQUE INDEX ux_treatments_vigente
    ON treatments (patient_id) WHERE status = 'vigente';

-- Historial de un paciente (más reciente primero).
CREATE INDEX ix_treatments_patient
    ON treatments (patient_id, effective_from DESC);

CREATE TRIGGER tg_treatments_updated_at
    BEFORE UPDATE ON treatments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  treatments IS
    'Esquema farmacológico de un paciente definido por el médico. Un solo vigente por paciente; los demás quedan como histórico (status=superseded) enlazados por supersedes_id. Cambiar el esquema crea uno nuevo, no edita en el lugar (DEF-007/008).';
COMMENT ON COLUMN treatments.status IS 'vigente | superseded | cancelled. Solo uno vigente por paciente.';
COMMENT ON COLUMN treatments.prescribed_by IS 'Médico que definió el tratamiento. Siempre registrado (DEF-006).';
COMMENT ON COLUMN treatments.supersedes_id IS 'Tratamiento anterior que este reemplazó. Arma la línea de tiempo.';
COMMENT ON COLUMN treatments.effective_from IS 'Desde cuándo rige. Puede fecharse en el pasado (indicado ayer, registrado hoy).';
COMMENT ON COLUMN treatments.effective_to IS 'Cuándo dejó de regir. NULL mientras está vigente.';


-- ─────────────────────────────────────────────────────────────────
-- treatment_items — cada indicación farmacológica dentro de un tratamiento
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE treatment_items (
    id                uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_id      uuid         NOT NULL,
    name              varchar(120) NOT NULL,
    dose_amount       numeric(8,2) NOT NULL,
    dose_unit         varchar(20)  NOT NULL,
    dose_text         varchar(60)  GENERATED ALWAYS AS
                          (trim_scale(dose_amount)::text || ' ' || dose_unit) STORED,
    instructions      text,
    grace_window_min  smallint     NOT NULL DEFAULT 60,
    -- Continuidad entre versiones del MISMO fármaco (losartán 50 → 100).
    continues_item_id uuid,
    -- Qué pasó con esta indicación respecto del tratamiento anterior.
    action            varchar(10)  NOT NULL DEFAULT 'kept',
    created_at        timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_treatment_items_treatment
        FOREIGN KEY (treatment_id) REFERENCES treatments(id) ON DELETE RESTRICT,
    CONSTRAINT fk_treatment_items_continues
        FOREIGN KEY (continues_item_id) REFERENCES treatment_items(id) ON DELETE RESTRICT,
    CONSTRAINT ck_treatment_items_dose_amount
        CHECK (dose_amount > 0),
    CONSTRAINT ck_treatment_items_name_min
        CHECK (char_length(name) >= 2),
    CONSTRAINT ck_treatment_items_grace
        CHECK (grace_window_min BETWEEN 5 AND 720),
    CONSTRAINT ck_treatment_items_dose_unit
        CHECK (dose_unit IN ('mg','g','ml','mcg','UI','gotas','comprimido','cápsula','puff','parche')),
    CONSTRAINT ck_treatment_items_action
        CHECK (action IN ('added', 'kept', 'changed', 'removed'))
);

-- Items de un tratamiento.
CREATE INDEX ix_treatment_items_treatment
    ON treatment_items (treatment_id);

-- Cadena de versiones de un fármaco (para la línea de tiempo).
CREATE INDEX ix_treatment_items_continues
    ON treatment_items (continues_item_id) WHERE continues_item_id IS NOT NULL;

COMMENT ON TABLE  treatment_items IS
    'Indicación farmacológica dentro de un tratamiento: fármaco + dosis + frecuencia. Las dosis concretas (scheduled_doses) cuelgan de aquí. Reemplaza, con versionado, a la fila suelta de medications.';
COMMENT ON COLUMN treatment_items.continues_item_id IS 'Versión anterior del mismo fármaco. NULL si es nuevo (action=added).';
COMMENT ON COLUMN treatment_items.action IS 'added | kept | changed | removed. Respecto del tratamiento anterior. removed = el fármaco salió del esquema.';


-- ─────────────────────────────────────────────────────────────────
-- treatment_item_times / treatment_item_days — 1FN, igual que medications
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE treatment_item_times (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_item_id uuid NOT NULL,
    time_of_day       time NOT NULL,

    CONSTRAINT fk_treatment_item_times_item
        FOREIGN KEY (treatment_item_id) REFERENCES treatment_items(id) ON DELETE RESTRICT,
    CONSTRAINT uq_treatment_item_times_slot
        UNIQUE (treatment_item_id, time_of_day)
);

CREATE INDEX ix_treatment_item_times_item
    ON treatment_item_times (treatment_item_id);

CREATE TABLE treatment_item_days (
    treatment_item_id uuid     NOT NULL,
    day_of_week       smallint NOT NULL,

    PRIMARY KEY (treatment_item_id, day_of_week),

    CONSTRAINT fk_treatment_item_days_item
        FOREIGN KEY (treatment_item_id) REFERENCES treatment_items(id) ON DELETE RESTRICT,
    CONSTRAINT ck_treatment_item_days_range
        CHECK (day_of_week BETWEEN 1 AND 7)
);

COMMENT ON TABLE treatment_item_times IS 'Horarios de toma de cada indicación (1FN). HH:MM en la zona del paciente.';
COMMENT ON TABLE treatment_item_days IS 'Días habilitados de cada indicación (1FN). 1=lunes … 7=domingo.';


-- treatment_documents (vínculo con la receta formal, DEF-014) vive en
-- 516_treatment_documents.sql porque medical_documents se crea en el bloque 5
-- (515), después de este archivo. Separarlo evita una FK a una tabla que aún
-- no existe durante la carga inicial.


-- ─────────────────────────────────────────────────────────────────
-- scheduled_doses.treatment_item_id — las dosis cuelgan de la indicación
-- ─────────────────────────────────────────────────────────────────
-- Durante la transición conviven medication_id y treatment_item_id. Al menos
-- uno debe estar presente. El generador de dosis pasa a usar los items.
ALTER TABLE scheduled_doses
    ADD COLUMN IF NOT EXISTS treatment_item_id uuid;

ALTER TABLE scheduled_doses
    DROP CONSTRAINT IF EXISTS fk_scheduled_doses_treatment_item;
ALTER TABLE scheduled_doses
    ADD CONSTRAINT fk_scheduled_doses_treatment_item
        FOREIGN KEY (treatment_item_id) REFERENCES treatment_items(id) ON DELETE RESTRICT;

-- medication_id deja de ser obligatorio: una dosis puede venir de un item.
ALTER TABLE scheduled_doses
    ALTER COLUMN medication_id DROP NOT NULL;

ALTER TABLE scheduled_doses
    DROP CONSTRAINT IF EXISTS ck_scheduled_doses_origen;
ALTER TABLE scheduled_doses
    ADD CONSTRAINT ck_scheduled_doses_origen
        CHECK (medication_id IS NOT NULL OR treatment_item_id IS NOT NULL);

-- Unicidad del slot por item (el job no duplica dosis de una misma indicación).
CREATE UNIQUE INDEX IF NOT EXISTS uq_scheduled_doses_item_slot
    ON scheduled_doses (treatment_item_id, scheduled_at)
    WHERE treatment_item_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_scheduled_doses_item
    ON scheduled_doses (treatment_item_id) WHERE treatment_item_id IS NOT NULL;

COMMENT ON COLUMN scheduled_doses.treatment_item_id IS
    'Indicación de la que nace la dosis. Reemplaza a medication_id en el modelo de tratamientos; conviven durante la transición (ck_scheduled_doses_origen exige al menos uno).';

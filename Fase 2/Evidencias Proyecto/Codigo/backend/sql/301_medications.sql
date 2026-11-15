-- AgeCare — Bloque 3: Medicación
-- Tabla 1 de 2: medications
--
-- Correcciones 2FN aplicadas:
--   · times jsonb eliminado → tabla medication_times (1FN: no grupos repetidos)
--   · days_of_week jsonb eliminado → tabla medication_days (1FN: no grupos repetidos)

CREATE TABLE medications (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid        NOT NULL,
    name            varchar(120) NOT NULL,
    -- Análisis de realidad: la dosis es cantidad + unidad, no un texto libre.
    -- Separarlas permite validar, comparar y (a futuro) calcular equivalencias.
    -- dose_text queda como presentación generada para la interfaz.
    dose_amount     numeric(8,2) NOT NULL,
    dose_unit       varchar(20)  NOT NULL,
    -- trim_scale()::text es inmutable (requisito de columna generada STORED);
    -- to_char() no lo es porque depende de lc_numeric de la sesión.
    dose_text       varchar(60)  GENERATED ALWAYS AS
                        (trim_scale(dose_amount)::text || ' ' || dose_unit) STORED,
    instructions    text,
    start_date      date         NOT NULL,
    end_date        date,
    grace_window_min smallint    NOT NULL DEFAULT 60,
    prescribed_by   uuid,
    discontinued_at timestamptz,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_medications_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_medications_prescriber
        FOREIGN KEY (prescribed_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT ck_medications_dates
        CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT ck_medications_grace
        CHECK (grace_window_min BETWEEN 5 AND 720),
    CONSTRAINT ck_medications_name_min
        CHECK (char_length(name) >= 2),
    CONSTRAINT ck_medications_dose_amount
        CHECK (dose_amount > 0),
    CONSTRAINT ck_medications_dose_unit
        CHECK (dose_unit IN ('mg','g','ml','mcg','UI','gotas','comprimido','cápsula','puff','parche'))
);

-- Plan vigente de un paciente (endpoint 6.2) y el job generador de dosis.
CREATE INDEX ix_medications_patient_active
    ON medications (patient_id) WHERE discontinued_at IS NULL;

CREATE TRIGGER tg_medications_updated_at
    BEFORE UPDATE ON medications
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  medications IS
    'Plan de medicamentos: QUÉ se administra y CON QUÉ FRECUENCIA. Las tomas concretas se materializan en scheduled_doses. Los horarios y días viven en medication_times y medication_days (1FN).';
COMMENT ON COLUMN medications.dose_amount IS
    'Cantidad numérica de la dosis (p. ej. 50). Separada de la unidad para poder validar y comparar; antes era un varchar "50 mg" no computable.';
COMMENT ON COLUMN medications.dose_unit IS
    'Unidad de la dosis: mg | g | ml | mcg | UI | gotas | comprimido | cápsula | puff | parche.';
COMMENT ON COLUMN medications.dose_text IS
    'Presentación generada (dose_amount + dose_unit) para la interfaz. Solo lectura.';
COMMENT ON COLUMN medications.grace_window_min IS
    'Minutos de tolerancia tras la hora programada antes de marcar la dosis como omitida y alertar (Anexo B).';
COMMENT ON COLUMN medications.prescribed_by IS
    'Quién definió el plan: médico o cuidadora (RF-24). ON DELETE RESTRICT: el plan y su responsable se conservan.';
COMMENT ON COLUMN medications.discontinued_at IS
    'Descontinuación. Cancela las tomas futuras y conserva el historial (RF-27). NULL = vigente.';


-- ─────────────────────────────────────────────────────────────────
-- medication_times
-- Normalización 1FN: reemplaza la columna times jsonb de medications.
-- Cada horario de toma es una entidad propia (una fila, un valor atómico).
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE medication_times (
    id            uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    medication_id uuid    NOT NULL,
    time_of_day   time    NOT NULL,

    CONSTRAINT fk_medication_times_medication
        FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE RESTRICT,
    -- Un medicamento no puede tener el mismo horario dos veces
    CONSTRAINT uq_medication_times_slot
        UNIQUE (medication_id, time_of_day)
);

-- El job generador de dosis consulta todos los horarios de un medicamento.
CREATE INDEX ix_medication_times_medication
    ON medication_times (medication_id);

COMMENT ON TABLE  medication_times IS
    'Horarios de toma de cada medicamento. Normalización 1FN: reemplaza el arreglo JSON times de medications. Cada fila = un horario atómico (HH:MM).';
COMMENT ON COLUMN medication_times.time_of_day IS
    'Hora de toma en la zona horaria del paciente (patients.timezone). Tipo TIME sin zona: la conversión la aplica el job al generar scheduled_doses.';


-- ─────────────────────────────────────────────────────────────────
-- medication_days
-- Normalización 1FN: reemplaza la columna days_of_week jsonb de medications.
-- Cada día habilitado es una fila propia.
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE medication_days (
    medication_id uuid     NOT NULL,
    day_of_week   smallint NOT NULL,

    PRIMARY KEY (medication_id, day_of_week),

    CONSTRAINT fk_medication_days_medication
        FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE RESTRICT,
    -- 1 = lunes … 7 = domingo (ISO 8601)
    CONSTRAINT ck_medication_days_range
        CHECK (day_of_week BETWEEN 1 AND 7)
);

COMMENT ON TABLE  medication_days IS
    'Días de la semana habilitados para cada medicamento. Normalización 1FN: reemplaza el arreglo JSON days_of_week de medications. PK compuesta (medication_id, day_of_week): cada fila es atómica.';
COMMENT ON COLUMN medication_days.day_of_week IS
    '1 = lunes, 2 = martes, …, 7 = domingo. ISO 8601. Sin fila = ese día no se administra.';

-- AgeCare — Bloque 3: Medicación
-- Tabla 1 de 2: medications

CREATE TABLE medications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid NOT NULL,
    name varchar(120) NOT NULL,
    dose varchar(60)  NOT NULL,
    instructions text,
    times jsonb NOT NULL,
    days_of_week jsonb NOT NULL DEFAULT '[1,2,3,4,5,6,7]'::jsonb,
    start_date date NOT NULL,
    end_date date,
    grace_window_min smallint NOT NULL DEFAULT 60,
    prescribed_by uuid,
    discontinued_at timestamptz,
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz  NOT NULL DEFAULT now(),

CONSTRAINT fk_medications_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_medications_prescriber
    FOREIGN KEY (prescribed_by) REFERENCES users(id) ON DELETE SET NULL,
CONSTRAINT ck_medications_dates
    CHECK (end_date IS NULL OR end_date >= start_date),
CONSTRAINT ck_medications_grace
    CHECK (grace_window_min BETWEEN 5 AND 720),
CONSTRAINT ck_medications_times_array
    CHECK (jsonb_typeof(times) = 'array' AND jsonb_array_length(times) > 0),
CONSTRAINT ck_medications_days_array
    CHECK (jsonb_typeof(days_of_week) = 'array' AND jsonb_array_length(days_of_week) > 0)
);

-- El plan vigente de un paciente (endpoint 6.2) y el job generador de dosis.
CREATE INDEX ix_medications_patient_active
    ON medications (patient_id) WHERE discontinued_at IS NULL;

CREATE TRIGGER tg_medications_updated_at
    BEFORE UPDATE ON medications
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  medications IS
    'Plan de medicamentos: QUÉ se administra y CON QUÉ FRECUENCIA. Las tomas concretas se materializan en scheduled_doses.';
COMMENT ON COLUMN medications.times IS
    'Horarios de toma, como arreglo JSON de "HH:MM". Se interpretan en la zona horaria del paciente (RF-32). Sin normalizar: se lee completo para generar dosis, nunca se filtra por horario.';
COMMENT ON COLUMN medications.days_of_week IS
    'Días de la semana, 1 = lunes a 7 = domingo. Por defecto todos.';
COMMENT ON COLUMN medications.grace_window_min IS
    'Minutos de tolerancia tras la hora programada antes de marcar la dosis como omitida y alertar (Anexo B).';
COMMENT ON COLUMN medications.prescribed_by IS
    'Quién definió el plan: médico o cuidadora (RF-24). ON DELETE SET NULL: el plan sobrevive a la cuenta.';
COMMENT ON COLUMN medications.discontinued_at IS
    'Descontinuación. Cancela las tomas futuras y conserva el historial (RF-27). NULL = vigente.';

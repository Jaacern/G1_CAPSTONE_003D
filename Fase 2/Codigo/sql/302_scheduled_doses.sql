
-- AgeCare — Bloque 3: Medicación
-- Tabla 2 de 2: scheduled_doses

CREATE TABLE scheduled_doses (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
medication_id uuid NOT NULL,
patient_id uuid NOT NULL,
scheduled_at timestamptz NOT NULL,
status varchar(10) NOT NULL DEFAULT 'pending',
logged_by uuid,
logged_at timestamptz,
reason varchar(200),
postponed_until timestamptz,
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_scheduled_doses_medication
    FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE CASCADE,
CONSTRAINT fk_scheduled_doses_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_scheduled_doses_user
    FOREIGN KEY (logged_by) REFERENCES users(id) ON DELETE SET NULL,

-- Idempotencia del job generador
CONSTRAINT uq_scheduled_doses_slot
    UNIQUE (medication_id, scheduled_at),

CONSTRAINT ck_scheduled_doses_status
    CHECK (status IN ('pending','taken','skipped','postponed','missed')),
-- RF-29: omitir exige motivo
CONSTRAINT ck_scheduled_doses_skip_reason
    CHECK (status <> 'skipped' OR reason IS NOT NULL),
-- Quién y cuándo van juntos
CONSTRAINT ck_scheduled_doses_logged_pair
    CHECK ((logged_at IS NULL) = (logged_by IS NULL)),
-- Confirmar o descartar requiere registro
CONSTRAINT ck_scheduled_doses_logged_status
    CHECK (status NOT IN ('taken','skipped') OR logged_at IS NOT NULL),
-- Posponer exige nueva hora
CONSTRAINT ck_scheduled_doses_postponed
    CHECK (status <> 'postponed' OR postponed_until IS NOT NULL),
CONSTRAINT ck_scheduled_doses_postpone_limit
    CHECK (postponed_until IS NULL OR
        postponed_until <= scheduled_at + interval '4 hours')
);

-- Agenda del día de la cuidadora y adherencia.
CREATE INDEX ix_scheduled_doses_patient_time
    ON scheduled_doses (patient_id, scheduled_at DESC);

-- El vigilante de ventanas vencidas.
CREATE INDEX ix_scheduled_doses_pending
    ON scheduled_doses (scheduled_at) WHERE status = 'pending';

CREATE TRIGGER tg_scheduled_doses_updated_at
    BEFORE UPDATE ON scheduled_doses
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  scheduled_doses IS
    'Tomas concretas generadas a partir del plan. Existen ANTES de ocurrir, lo que permite registrar las ausencias y calcular la adherencia: sin estas filas no habría denominador.';
COMMENT ON COLUMN scheduled_doses.status IS
    'pending | taken | skipped | postponed | missed. Se almacena aunque missed sea deducible, porque el cambio de estado dispara una alerta y porque la adherencia se consulta sobre rangos amplios.';
COMMENT ON COLUMN scheduled_doses.reason IS
    'Motivo de la omisión. Obligatorio cuando el estado es skipped (RF-29).';
COMMENT ON COLUMN scheduled_doses.postponed_until IS
    'Nueva hora tras posponer. Máximo 4 horas después de lo programado (endpoint 6.6).';
COMMENT ON COLUMN scheduled_doses.patient_id IS
    'Redundante respecto de medications.patient_id, pero evita un JOIN en la consulta más frecuente: la agenda del día.';

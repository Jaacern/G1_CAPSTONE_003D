-- AgeCare — Bloque 3: Medicación
-- Tabla 2 de 2: scheduled_doses
--
-- Correcciones 2FN aplicadas:
--   · patient_id eliminado: dependencia parcial (patient_id dependía de medication_id,
--     no de la PK id). Viola 2FN. Las consultas por paciente hacen JOIN con medications.

CREATE TABLE scheduled_doses (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    medication_id uuid        NOT NULL,
    scheduled_at  timestamptz NOT NULL,
    status        varchar(10) NOT NULL DEFAULT 'pending',
    logged_by     uuid,
    logged_at     timestamptz,
    reason        varchar(200),
    postponed_until timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_scheduled_doses_medication
        FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE CASCADE,
    CONSTRAINT fk_scheduled_doses_user
        FOREIGN KEY (logged_by) REFERENCES users(id) ON DELETE SET NULL,

    -- Idempotencia del job generador: un slot por medicamento y hora
    CONSTRAINT uq_scheduled_doses_slot
        UNIQUE (medication_id, scheduled_at),

    CONSTRAINT ck_scheduled_doses_status
        CHECK (status IN ('pending','taken','skipped','postponed','missed')),
    -- RF-29: omitir exige motivo
    CONSTRAINT ck_scheduled_doses_skip_reason
        CHECK (status <> 'skipped' OR reason IS NOT NULL),
    -- Quién y cuándo van siempre juntos
    CONSTRAINT ck_scheduled_doses_logged_pair
        CHECK ((logged_at IS NULL) = (logged_by IS NULL)),
    -- Confirmar o descartar requiere registro de quién y cuándo
    CONSTRAINT ck_scheduled_doses_logged_status
        CHECK (status NOT IN ('taken','skipped') OR logged_at IS NOT NULL),
    -- Posponer exige nueva hora
    CONSTRAINT ck_scheduled_doses_postponed
        CHECK (status <> 'postponed' OR postponed_until IS NOT NULL),
    -- Máximo 4 horas de postergación (endpoint 6.6)
    CONSTRAINT ck_scheduled_doses_postpone_limit
        CHECK (postponed_until IS NULL OR
            postponed_until <= scheduled_at + interval '4 hours')
);

-- Agenda del día: JOIN con medications para obtener patient_id.
-- La consulta más frecuente: dosis pendientes de un paciente en una fecha.
--   SELECT sd.*
--   FROM scheduled_doses sd
--   JOIN medications m ON m.id = sd.medication_id
--   WHERE m.patient_id = $1
--     AND sd.scheduled_at::date = $2
--   ORDER BY sd.scheduled_at;
CREATE INDEX ix_scheduled_doses_medication_time
    ON scheduled_doses (medication_id, scheduled_at DESC);

-- El vigilante de ventanas vencidas (Anexo B).
CREATE INDEX ix_scheduled_doses_pending
    ON scheduled_doses (scheduled_at) WHERE status = 'pending';

CREATE TRIGGER tg_scheduled_doses_updated_at
    BEFORE UPDATE ON scheduled_doses
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  scheduled_doses IS
    'Tomas concretas generadas a partir del plan (medications + medication_times + medication_days). Existen ANTES de ocurrir, lo que permite registrar ausencias y calcular adherencia: sin estas filas no habría denominador.';
COMMENT ON COLUMN scheduled_doses.status IS
    'pending | taken | skipped | postponed | missed.';
COMMENT ON COLUMN scheduled_doses.reason IS
    'Motivo de la omisión. Obligatorio cuando el estado es skipped (RF-29).';
COMMENT ON COLUMN scheduled_doses.postponed_until IS
    'Nueva hora tras posponer. Máximo 4 horas después de lo programado (endpoint 6.6).';

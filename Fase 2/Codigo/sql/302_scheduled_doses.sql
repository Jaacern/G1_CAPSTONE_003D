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
    -- Análisis de realidad: tres momentos DISTINTOS que no deben confundirse.
    --   scheduled_at   = cuándo DEBÍA administrarse la dosis (planificado).
    --   administered_at= cuándo REALMENTE se administró al paciente (hecho clínico).
    --   logged_at      = cuándo la cuidadora lo REGISTRÓ en la app (acto administrativo).
    -- Permite distinguir "se dio a tiempo pero se registró tarde" de "se dio tarde".
    administered_at timestamptz,
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
    -- Una dosis administrada debe tener la hora real de administración.
    CONSTRAINT ck_scheduled_doses_administered
        CHECK (status <> 'taken' OR administered_at IS NOT NULL),
    -- No se puede administrar una dosis antes de que estuviera programada.
    CONSTRAINT ck_scheduled_doses_admin_order
        CHECK (administered_at IS NULL OR administered_at >= scheduled_at),
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
COMMENT ON COLUMN scheduled_doses.scheduled_at IS
    'Momento en que la dosis DEBÍA administrarse (planificado por el job según el plan).';
COMMENT ON COLUMN scheduled_doses.administered_at IS
    'Momento REAL de administración al paciente (hecho clínico). Distinto de logged_at: una dosis puede darse a las 08:00 y registrarse a las 23:00. Base para medir puntualidad real, no solo adherencia administrativa.';
COMMENT ON COLUMN scheduled_doses.logged_at IS
    'Momento en que la cuidadora REGISTRÓ la dosis en la app (acto administrativo). Junto con logged_by da trazabilidad y responsabilidad del registro.';
COMMENT ON COLUMN scheduled_doses.logged_by IS
    'Usuario que registró la dosis. Es la rendición de cuentas del acto: el sistema no puede validar la administración física, pero sí dejar evidencia inmutable de quién la declaró y cuándo.';
COMMENT ON COLUMN scheduled_doses.reason IS
    'Motivo de la omisión. Obligatorio cuando el estado es skipped (RF-29).';
COMMENT ON COLUMN scheduled_doses.postponed_until IS
    'Nueva hora tras posponer. Máximo 4 horas después de lo programado (endpoint 6.6).';

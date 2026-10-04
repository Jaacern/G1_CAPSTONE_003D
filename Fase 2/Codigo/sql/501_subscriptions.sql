-- AgeCare — Bloque 5: Negocio (freemium)
-- Tabla: subscriptions
--
-- Análisis de negocio (RF-73, objetivo de conversión del modelo freemium):
--   El documento de negocio promete un modelo freemium con conversión a Premium.
--   Sin una tabla que modele el estado de suscripción, el objetivo "10% de
--   conversión" no es medible ni el requisito RF-73 ("bloquear funciones de pago
--   sin suscripción vigente") es implementable: no habría contra qué validar.
--
--   La suscripción pertenece a un USUARIO (la cuidadora en v1, extensible a
--   familiar). Una fila representa un período de suscripción; el historial se
--   conserva (no se borra al expirar) para analítica de retención y churn.

CREATE TABLE subscriptions (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid        NOT NULL,
    plan          varchar(20) NOT NULL,
    status        varchar(20) NOT NULL DEFAULT 'active',
    started_at    timestamptz NOT NULL DEFAULT now(),
    -- Fin del período vigente. NULL mientras esté activa sin fecha de corte.
    current_period_end timestamptz,
    cancelled_at  timestamptz,
    -- Referencia opaca a la pasarela de pago (no se guardan datos de tarjeta).
    provider_ref  varchar(120),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_subscriptions_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT ck_subscriptions_plan
        CHECK (plan IN ('free','premium')),
    CONSTRAINT ck_subscriptions_status
        CHECK (status IN ('active','past_due','cancelled','expired')),
    -- Cancelar exige marca de tiempo de cancelación.
    CONSTRAINT ck_subscriptions_cancelled_pair
        CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL)
);

-- Suscripción vigente de un usuario (la consulta de RF-73 al bloquear premium).
-- Un solo registro ACTIVO por usuario; el historial de períodos cerrados se conserva.
CREATE UNIQUE INDEX ux_subscriptions_active_user
    ON subscriptions (user_id) WHERE status = 'active';

CREATE INDEX ix_subscriptions_user
    ON subscriptions (user_id, created_at DESC);

CREATE TRIGGER tg_subscriptions_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  subscriptions IS
    'Suscripciones del modelo freemium (RF-73). Da soporte a la validación de acceso a funciones de pago y a la métrica de conversión del plan de negocio. Conserva el historial de períodos para analítica de retención.';
COMMENT ON COLUMN subscriptions.plan IS
    'free | premium. El adulto mayor nunca paga; en v1 la suscripción aplica a la cuidadora.';
COMMENT ON COLUMN subscriptions.status IS
    'active | past_due | cancelled | expired. Solo una activa por usuario (índice parcial).';
COMMENT ON COLUMN subscriptions.provider_ref IS
    'Referencia opaca a la pasarela de pago. NO se almacenan datos de tarjeta (cumplimiento PCI).';

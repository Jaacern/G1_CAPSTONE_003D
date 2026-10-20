-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 707_usage_counters.sql — Contadores de consumo por periodo
-- Requisitos: RF-73 (bloquear funciones premium sin suscripcion)
-- ----------------------------------------------------------------------------
-- plan_limits dice cuanto se puede. Esta tabla dice cuanto se uso. RF-73 se
-- cumple comparando las dos:
--
--   SELECT  l.limit_value, c.used_value
--     FROM  subscriptions s
--     JOIN  plan_limits   l ON l.plan_id = s.plan_id
--     LEFT JOIN usage_counters c
--            ON  c.subscription_id = s.id
--           AND  c.limit_key       = l.limit_key
--           AND  c.period_start    = date_trunc('month', now())::date
--    WHERE  s.id = $1 AND l.limit_key = 'ai_queries_month';
--
-- Si used_value alcanza limit_value, la funcion se bloquea. Sin esta tabla,
-- "bloquear premium" solo se puede implementar contando filas de otras tablas
-- en cada peticion, que es lento y no sirve para limites por periodo.
--
-- period_start guarda el primer dia del periodo, no un rango. Asi el contador
-- de cada mes es una fila distinta y el historial de consumo queda disponible
-- para el analisis que piden los profesores, en vez de reiniciarse a cero
-- sobre la misma fila.
--
-- limit_key no tiene FK porque la clave de plan_limits es compuesta
-- (plan_id, limit_key) y aqui no se conoce el plan: la suscripcion puede
-- cambiar de plan en medio del mes y el consumo del mes sigue siendo el mismo.
-- El formato se valida con el mismo CHECK que en plan_limits.
-- ============================================================================

CREATE TABLE usage_counters (
    subscription_id uuid        NOT NULL,
    limit_key       varchar(40) NOT NULL,
    period_start    date        NOT NULL,
    used_value      integer     NOT NULL DEFAULT 0,
    last_used_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (subscription_id, limit_key, period_start),

    CONSTRAINT fk_usage_counters_subscription
        FOREIGN KEY (subscription_id) REFERENCES subscriptions(id) ON DELETE RESTRICT,

    CONSTRAINT ck_usage_counters_key CHECK (limit_key ~ '^[a-z][a-z0-9_]{2,39}$'),
    CONSTRAINT ck_usage_counters_value CHECK (used_value >= 0),
    -- El periodo siempre empieza el dia 1. Evita que dos filas representen el
    -- mismo mes con fechas distintas.
    CONSTRAINT ck_usage_counters_periodo CHECK (
        period_start = date_trunc('month', period_start)::date
    )
);

-- Consumo del periodo en curso de una suscripcion.
CREATE INDEX ix_usage_counters_periodo
    ON usage_counters (subscription_id, period_start DESC);

COMMENT ON TABLE  usage_counters IS 'Consumo acumulado por suscripcion, limite y periodo mensual. Comparado contra plan_limits es lo que permite bloquear funciones premium. RF-73.';
COMMENT ON COLUMN usage_counters.subscription_id IS 'Suscripcion que consume.';
COMMENT ON COLUMN usage_counters.limit_key IS 'Limite que se esta midiendo. Mismo nombre que en plan_limits.';
COMMENT ON COLUMN usage_counters.period_start IS 'Primer dia del mes al que corresponde el contador.';
COMMENT ON COLUMN usage_counters.used_value IS 'Cantidad consumida en el periodo.';
COMMENT ON COLUMN usage_counters.last_used_at IS 'Ultima vez que el contador aumento.';
COMMENT ON COLUMN usage_counters.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN usage_counters.updated_at IS 'Fecha de la ultima actualizacion del contador.';

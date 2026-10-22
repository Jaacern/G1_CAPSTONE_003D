-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 704_plan_limits.sql — Limites numericos por plan
-- Requisitos: RF-73, RF-83 a RF-85
-- ----------------------------------------------------------------------------
-- plan_features responde preguntas de si o no. plan_limits responde preguntas
-- de cuanto: cuantos pacientes, cuantos miembros por circulo, cuantos dias de
-- historial, cuantas consultas al asistente por mes.
--
-- Se modela como pares clave-valor y no como columnas fijas (max_patients,
-- max_members, ...) porque el constructor de planes de Alloxentric tiene que
-- poder agregar un limite nuevo sin que eso signifique un ALTER TABLE y un
-- despliegue. Es la misma decision que ya se tomo en system_parameters.
--
-- limit_value nulo significa SIN LIMITE. No se usa -1 para eso: un numero
-- magico obliga a que cada consulta se acuerde de la convencion, mientras que
-- NULL ya significa "no aplica" en SQL y las comparaciones se comportan solas.
-- ============================================================================

CREATE TABLE plan_limits (
    plan_id     uuid        NOT NULL,
    limit_key   varchar(40) NOT NULL,
    limit_value integer,
    unit        varchar(20) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (plan_id, limit_key),

    CONSTRAINT fk_plan_limits_plan
        FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE RESTRICT,

    CONSTRAINT ck_plan_limits_key CHECK (limit_key ~ '^[a-z][a-z0-9_]{2,39}$'),
    -- Nulo es sin limite; si hay numero, no puede ser negativo.
    CONSTRAINT ck_plan_limits_value CHECK (
        limit_value IS NULL OR limit_value >= 0
    ),
    CONSTRAINT ck_plan_limits_unit CHECK (
        unit IN ('count','days','months','megabytes','per_month','per_day')
    )
);

COMMENT ON TABLE  plan_limits IS 'Limites numericos de cada plan, como pares clave-valor para que el constructor pueda agregar limites sin modificar la tabla. Nulo significa sin limite. RF-73, RF-83 a RF-85.';
COMMENT ON COLUMN plan_limits.plan_id IS 'Plan al que aplica el limite.';
COMMENT ON COLUMN plan_limits.limit_key IS 'Nombre del limite, por ejemplo max_patients o history_days.';
COMMENT ON COLUMN plan_limits.limit_value IS 'Valor del limite. Nulo significa sin limite.';
COMMENT ON COLUMN plan_limits.unit IS 'Unidad en que se expresa el limite.';
COMMENT ON COLUMN plan_limits.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN plan_limits.updated_at IS 'Fecha de la ultima modificacion del registro.';

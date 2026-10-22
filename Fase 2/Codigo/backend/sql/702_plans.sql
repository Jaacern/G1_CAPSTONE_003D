-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 702_plans.sql — Planes comerciales
-- Requisitos: RF-73, RF-83 a RF-85 (constructor de planes de Alloxentric)
-- ----------------------------------------------------------------------------
-- El plan tiene ciclo de vida propio: se arma en borrador, se publica y
-- eventualmente se archiva. Nunca se borra, porque hay suscripciones
-- historicas que apuntan a el y eventos de cobro que se emitieron con sus
-- condiciones. Archivar significa que no se puede contratar mas, no que
-- desaparezca.
--
-- El precio NO esta aqui. Vive en plan_prices con vigencia, porque un plan
-- dura anos y su precio cambia varias veces en ese plazo. Si el precio fuera
-- una columna de esta tabla, cada cambio de precio reescribiria el plan y los
-- cobros viejos quedarian apuntando a un monto que ya no es el que se cobro.
-- ============================================================================

CREATE TABLE plans (
    id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code         varchar(20)  NOT NULL,
    name         varchar(60)  NOT NULL,
    description  varchar(300),
    tier         smallint     NOT NULL,
    is_public    boolean      NOT NULL DEFAULT true,
    status       varchar(12)  NOT NULL DEFAULT 'draft',
    created_by   uuid,
    published_at timestamptz,
    archived_at  timestamptz,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    updated_at   timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_plans_created_by
        FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT uq_plans_code UNIQUE (code),

    CONSTRAINT ck_plans_code CHECK (code ~ '^[a-z][a-z0-9_]{2,19}$'),
    CONSTRAINT ck_plans_name CHECK (btrim(name) <> ''),
    -- tier 0 es el plan gratuito; de ahi para arriba, mayor jerarquia.
    CONSTRAINT ck_plans_tier CHECK (tier BETWEEN 0 AND 10),
    CONSTRAINT ck_plans_status CHECK (
        status IN ('draft','active','archived')
    ),
    -- Un plan activo tiene fecha de publicacion; uno archivado, de archivo.
    CONSTRAINT ck_plans_status_fechas CHECK (
        (status = 'draft'    AND published_at IS NULL     AND archived_at IS NULL)
     OR (status = 'active'   AND published_at IS NOT NULL AND archived_at IS NULL)
     OR (status = 'archived' AND published_at IS NOT NULL AND archived_at IS NOT NULL)
    )
);

-- Solo puede haber un plan gratuito activo a la vez. Si hubiera dos, el
-- sistema no sabria a cual asignar una cuenta nueva.
CREATE UNIQUE INDEX uq_plans_gratuito_activo
    ON plans ((tier))
    WHERE tier = 0 AND status = 'active';

-- Pantalla publica de planes, en orden de jerarquia.
CREATE INDEX ix_plans_publicos
    ON plans (tier)
    WHERE status = 'active' AND is_public;

COMMENT ON TABLE  plans IS 'Planes comerciales de AgeCare. Tienen ciclo de vida (borrador, activo, archivado) y nunca se borran porque hay suscripciones e historial de cobros que los referencian. RF-83 a RF-85.';
COMMENT ON COLUMN plans.id IS 'Identificador del plan.';
COMMENT ON COLUMN plans.code IS 'Codigo estable del plan, por ejemplo free o premium.';
COMMENT ON COLUMN plans.name IS 'Nombre comercial que ve el usuario.';
COMMENT ON COLUMN plans.description IS 'Descripcion del plan para la pantalla de contratacion.';
COMMENT ON COLUMN plans.tier IS 'Jerarquia del plan. Cero es el plan gratuito.';
COMMENT ON COLUMN plans.is_public IS 'Verdadero si el plan se ofrece abiertamente. Falso para planes internos o a medida.';
COMMENT ON COLUMN plans.status IS 'Estado del plan: draft, active o archived. Archivado no se puede contratar.';
COMMENT ON COLUMN plans.created_by IS 'Usuario que creo el plan en el constructor.';
COMMENT ON COLUMN plans.published_at IS 'Momento en que el plan quedo disponible para contratar.';
COMMENT ON COLUMN plans.archived_at IS 'Momento en que el plan dejo de ofrecerse.';
COMMENT ON COLUMN plans.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN plans.updated_at IS 'Fecha de la ultima modificacion del registro.';

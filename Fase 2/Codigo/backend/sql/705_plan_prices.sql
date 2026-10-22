-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 705_plan_prices.sql — Precios con vigencia
-- Requisitos: RF-83 a RF-85
-- ----------------------------------------------------------------------------
-- El precio de un plan no es un dato, es una serie historica. Si se guardara
-- como columna de plans, subir el premium de 4.990 a 5.990 reescribiria el
-- plan y todos los cobros anteriores quedarian apuntando a un monto que nunca
-- se cobro. Aqui cada precio tiene vigencia, y los cobros apuntan a la fila de
-- precio que estaba vigente ese dia (706_billing_events.plan_price_id).
--
-- La restriccion EXCLUDE es la pieza importante: impide que un mismo plan
-- tenga dos precios vigentes al mismo tiempo en la misma moneda y periodo.
-- Un UNIQUE no puede expresar eso, porque el conflicto no es la igualdad de
-- una fecha sino el SOLAPAMIENTO de dos rangos. Con esto, el error de tener
-- dos precios validos a la vez es imposible, no solo improbable.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE plan_prices (
    id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id    uuid          NOT NULL,
    currency   char(3)       NOT NULL DEFAULT 'CLP',
    period     varchar(10)   NOT NULL,
    amount     numeric(12,2) NOT NULL,
    valid_from timestamptz   NOT NULL,
    valid_to   timestamptz,
    created_by uuid,
    created_at timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT fk_plan_prices_plan
        FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE RESTRICT,
    CONSTRAINT fk_plan_prices_created_by
        FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT ck_plan_prices_currency CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT ck_plan_prices_period CHECK (
        period IN ('monthly','yearly','once')
    ),
    CONSTRAINT ck_plan_prices_amount CHECK (amount >= 0),
    CONSTRAINT ck_plan_prices_vigencia CHECK (
        valid_to IS NULL OR valid_to > valid_from
    ),

    -- Nada de dos precios vigentes a la vez para el mismo plan, moneda y
    -- periodo. El motor rechaza el solapamiento de rangos.
    CONSTRAINT ex_plan_prices_sin_solape EXCLUDE USING gist (
        plan_id  WITH =,
        currency WITH =,
        period   WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    )
);

-- Precio vigente de un plan: la consulta de la pantalla de contratacion.
CREATE INDEX ix_plan_prices_vigentes
    ON plan_prices (plan_id, currency, period, valid_from DESC)
    WHERE valid_to IS NULL;

COMMENT ON TABLE  plan_prices IS 'Historial de precios de cada plan con vigencia. Una restriccion de exclusion impide dos precios vigentes a la vez para el mismo plan, moneda y periodo. RF-83 a RF-85.';
COMMENT ON COLUMN plan_prices.id IS 'Identificador del precio.';
COMMENT ON COLUMN plan_prices.plan_id IS 'Plan al que corresponde el precio.';
COMMENT ON COLUMN plan_prices.currency IS 'Moneda en codigo ISO de tres letras. Por omision CLP.';
COMMENT ON COLUMN plan_prices.period IS 'Periodo de cobro: monthly, yearly u once.';
COMMENT ON COLUMN plan_prices.amount IS 'Monto del plan en la moneda indicada.';
COMMENT ON COLUMN plan_prices.valid_from IS 'Inicio de vigencia del precio.';
COMMENT ON COLUMN plan_prices.valid_to IS 'Fin de vigencia. Nulo significa que es el precio actual.';
COMMENT ON COLUMN plan_prices.created_by IS 'Usuario que definio el precio.';
COMMENT ON COLUMN plan_prices.created_at IS 'Fecha de creacion del registro.';

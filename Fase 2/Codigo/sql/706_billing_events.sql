-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 706_billing_events.sql — Eventos de cobro
-- Requisitos: RF-73, RF-83 a RF-85
-- ----------------------------------------------------------------------------
-- Tabla append-only: un cobro ocurrio o no ocurrio. No tiene updated_at ni
-- deleted_at porque un hecho de facturacion no se corrige editandolo, se
-- corrige con otro evento (un refund). Es la misma logica de audit_log.
--
-- Lo que NO guarda, y es deliberado: numero de tarjeta, titular, CVV, fecha de
-- vencimiento. Nada de eso entra a la base. Solo provider_ref, que es una
-- referencia opaca de la pasarela, igual que ya hace subscriptions.provider_ref.
-- Guardar datos de tarjeta obligaria a cumplir PCI-DSS y no hay ninguna razon
-- para hacerlo cuando la pasarela ya los custodia.
--
-- provider_event_id es UNIQUE por idempotencia: las pasarelas reintentan sus
-- avisos, y sin esa restriccion un reintento cobraria dos veces en el
-- historial. El motor lo rechaza.
-- ============================================================================

CREATE TABLE billing_events (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id   uuid          NOT NULL,
    plan_price_id     uuid,
    type              varchar(20)   NOT NULL,
    status            varchar(12)   NOT NULL DEFAULT 'pending',
    amount            numeric(12,2),
    currency          char(3),
    period_start      timestamptz,
    period_end        timestamptz,
    provider_ref      varchar(120),
    provider_event_id varchar(120),
    failure_reason    varchar(200),
    occurred_at       timestamptz   NOT NULL,
    created_at        timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT fk_billing_events_subscription
        FOREIGN KEY (subscription_id) REFERENCES subscriptions(id) ON DELETE RESTRICT,
    CONSTRAINT fk_billing_events_plan_price
        FOREIGN KEY (plan_price_id) REFERENCES plan_prices(id) ON DELETE RESTRICT,

    -- Idempotencia frente a reintentos de la pasarela.
    CONSTRAINT uq_billing_events_provider UNIQUE (provider_event_id),

    CONSTRAINT ck_billing_events_type CHECK (
        type IN ('trial_started','charge','renewal','refund','chargeback',
                 'payment_failed','plan_changed','cancelled','expired')
    ),
    CONSTRAINT ck_billing_events_status CHECK (
        status IN ('pending','succeeded','failed')
    ),
    -- Si hay monto hay moneda, y al contrario. No existe un monto sin moneda.
    CONSTRAINT ck_billing_events_moneda CHECK (
        (amount IS NULL) = (currency IS NULL)
    ),
    CONSTRAINT ck_billing_events_currency CHECK (
        currency IS NULL OR currency ~ '^[A-Z]{3}$'
    ),
    -- Un reembolso es negativo y un cobro positivo. Asi la suma de la columna
    -- es el ingreso real sin tener que mirar el tipo de cada fila.
    CONSTRAINT ck_billing_events_signo CHECK (
        amount IS NULL
     OR (type IN ('refund','chargeback') AND amount <= 0)
     OR (type NOT IN ('refund','chargeback') AND amount >= 0)
    ),
    CONSTRAINT ck_billing_events_periodo CHECK (
        period_end IS NULL OR period_start IS NULL OR period_end > period_start
    ),
    -- Un fallo explica por que fallo.
    CONSTRAINT ck_billing_events_fallo CHECK (
        status <> 'failed' OR failure_reason IS NOT NULL
    )
);

-- Historial de facturacion de una suscripcion.
CREATE INDEX ix_billing_events_subscription
    ON billing_events (subscription_id, occurred_at DESC);

-- Cobros fallidos pendientes de reintento o de aviso al usuario.
CREATE INDEX ix_billing_events_fallidos
    ON billing_events (occurred_at DESC)
    WHERE status = 'failed';

COMMENT ON TABLE  billing_events IS 'Eventos de facturacion de cada suscripcion. Append-only. No almacena ningun dato de tarjeta, solo referencias opacas de la pasarela. RF-73, RF-83 a RF-85.';
COMMENT ON COLUMN billing_events.id IS 'Identificador del evento.';
COMMENT ON COLUMN billing_events.subscription_id IS 'Suscripcion a la que corresponde el evento.';
COMMENT ON COLUMN billing_events.plan_price_id IS 'Precio vigente con que se emitio el cobro. Conserva el monto historico.';
COMMENT ON COLUMN billing_events.type IS 'Tipo de evento: cobro, renovacion, reembolso, fallo, cambio de plan, baja.';
COMMENT ON COLUMN billing_events.status IS 'Resultado del evento: pending, succeeded o failed.';
COMMENT ON COLUMN billing_events.amount IS 'Monto del evento. Negativo en reembolsos y contracargos.';
COMMENT ON COLUMN billing_events.currency IS 'Moneda del monto, en codigo ISO de tres letras.';
COMMENT ON COLUMN billing_events.period_start IS 'Inicio del periodo que cubre el cobro.';
COMMENT ON COLUMN billing_events.period_end IS 'Fin del periodo que cubre el cobro.';
COMMENT ON COLUMN billing_events.provider_ref IS 'Referencia opaca de la transaccion en la pasarela.';
COMMENT ON COLUMN billing_events.provider_event_id IS 'Identificador del aviso de la pasarela. Unico, para que un reintento no duplique el cobro.';
COMMENT ON COLUMN billing_events.failure_reason IS 'Motivo del fallo. Obligatorio cuando el estado es failed.';
COMMENT ON COLUMN billing_events.occurred_at IS 'Momento en que ocurrio el evento segun la pasarela.';
COMMENT ON COLUMN billing_events.created_at IS 'Momento en que el evento se registro en AgeCare.';

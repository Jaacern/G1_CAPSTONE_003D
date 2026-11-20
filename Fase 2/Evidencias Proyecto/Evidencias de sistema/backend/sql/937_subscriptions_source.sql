-- AgeCare — Negocio (freemium)
-- 937_subscriptions_source.sql — De donde nace cada suscripcion
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--     Una suscripcion puede nacer de dos maneras muy distintas: el usuario
--     la compra (hay un cobro detras) o el personal de Alloxentric la
--     otorga a mano (cortesia, compensacion, correccion). Hasta ahora solo
--     se deducia de granted_by, y eso no sirve para medir: la conversion a
--     premium debe contar a quien paga, no a quien recibio una cortesia.
--
-- COMO QUEDA
--     subscriptions.source = 'purchase' | 'admin'. Todo lo anterior es
--     'purchase', salvo lo que ya tenia granted_by.
--
-- LA PASARELA DE PAGO
--     Alloxentric aun no define cual usara. Mientras tanto el cobro lo
--     hace un proveedor simulado (app/payment_provider.py) que deja los
--     mismos registros que dejaria uno real: una suscripcion con
--     source = 'purchase' y un evento 'charge' en billing_events. Cuando se
--     elija la pasarela, cambia el proveedor y nada de este modelo.

ALTER TABLE subscriptions
    ADD COLUMN IF NOT EXISTS source varchar(10) NOT NULL DEFAULT 'purchase';

UPDATE subscriptions SET source = 'admin'
 WHERE granted_by IS NOT NULL AND source <> 'admin';

ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS ck_subscriptions_source;
ALTER TABLE subscriptions
    ADD CONSTRAINT ck_subscriptions_source CHECK (source IN ('purchase', 'admin'));

COMMENT ON COLUMN subscriptions.source IS
    'purchase = la compro el usuario (hay un cobro en billing_events). admin = la otorgo el personal a mano (cortesia o correccion). La conversion a premium se mide solo sobre purchase.';

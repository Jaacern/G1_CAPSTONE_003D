-- AgeCare — Negocio (freemium)
-- 939_subscriptions_cancel.sql — Cancelar la renovacion sin perder lo ya pagado
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--     Quien se arrepiente de su suscripcion premium no tenia como cancelar.
--     Y cancelar no puede cortar el acceso en el acto: el periodo ya esta
--     pagado, y quitarlo seria cobrar por algo que no se entrega.
--
-- COMO QUEDA
--     cancel_requested_at marca que el usuario pidio no renovar. La
--     suscripcion sigue 'active' y con acceso hasta current_period_end;
--     despues deja de estar vigente sola, porque la consulta de plan vigente
--     ya exige current_period_end > now(). Cuando exista pasarela, es esta
--     marca la que impide el siguiente cobro.
--
--     status = 'cancelled' se reserva para cuando la suscripcion se cierra
--     de verdad (la reemplaza otra, o el personal la termina).

ALTER TABLE subscriptions
    ADD COLUMN IF NOT EXISTS cancel_requested_at timestamptz;

COMMENT ON COLUMN subscriptions.cancel_requested_at IS
    'Cuando el usuario pidio no renovar. NULL = renueva. La suscripcion conserva el acceso hasta current_period_end.';

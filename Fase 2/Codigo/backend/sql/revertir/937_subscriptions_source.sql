-- Revierte 937_subscriptions_source.sql
--
-- PIERDE DATOS: se olvida si la suscripcion nacio de una compra o la creo el
-- personal a mano. Si la 936 sigue aplicada, granted_by conserva parte de esa
-- informacion: una suscripcion con granted_by la otorgo el personal.

ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS ck_subscriptions_source;
ALTER TABLE subscriptions DROP COLUMN IF EXISTS source;

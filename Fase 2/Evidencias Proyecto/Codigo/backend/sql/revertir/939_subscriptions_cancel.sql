-- Revierte 939_subscriptions_cancel.sql
--
-- PIERDE DATOS: se olvida que alguien habia pedido cancelar su suscripcion.
-- La suscripcion sigue vigente; lo que desaparece es la solicitud.

ALTER TABLE subscriptions DROP COLUMN IF EXISTS cancel_requested_at;

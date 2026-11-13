-- Revierte 936_admin_usuarios.sql
--
-- PIERDE DATOS: se borra el registro de acciones del personal sobre las
-- cuentas, y se olvida que cuentas estaban desactivadas y por que. Una
-- cuenta desactivada vuelve a comportarse como activa.
--
-- OJO CON EL ORDEN: la 937 lee granted_by para marcar el origen de la
-- suscripcion. Revertir esta antes que aquella deja a la 937 sin la columna
-- de la que se apoya.

DROP INDEX IF EXISTS ix_admin_audit_objetivo;
DROP INDEX IF EXISTS ix_admin_audit_fecha;
DROP TABLE IF EXISTS admin_audit_log;

ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS fk_subscriptions_granted_by;
ALTER TABLE subscriptions DROP COLUMN IF EXISTS change_reason;
ALTER TABLE subscriptions DROP COLUMN IF EXISTS granted_by;

DROP INDEX IF EXISTS ix_users_desactivados;
ALTER TABLE users DROP CONSTRAINT IF EXISTS fk_users_deactivated_by;
ALTER TABLE users DROP COLUMN IF EXISTS deactivated_by;
ALTER TABLE users DROP COLUMN IF EXISTS deactivated_reason;
ALTER TABLE users DROP COLUMN IF EXISTS deactivated_at;

-- Revierte 929_usuarios_staff.sql
--
-- PIERDE DATOS: quien fuera personal deja de serlo. La marca is_staff vive
-- solo en esa columna.
--
-- La cuenta de administrador que sembro la migracion NO se borra. Para
-- cuando alguien revierta esto ya puede haber dejado rastro en
-- admin_audit_log y en suscripciones otorgadas a mano, y esas filas la
-- referencian. Sin la columna queda como un usuario comun, que es
-- justamente el estado anterior a la migracion.

DROP INDEX IF EXISTS ix_users_staff;
ALTER TABLE users DROP COLUMN IF EXISTS is_staff;

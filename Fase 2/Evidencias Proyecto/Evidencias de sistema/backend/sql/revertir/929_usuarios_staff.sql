-- Revierte 929_usuarios_staff.sql
--
-- PIERDE DATOS: quien fuera personal deja de serlo. La marca is_staff vive
-- solo en esa columna.
--
-- Esta migracion ya no siembra ninguna cuenta: el administrador de la
-- demostracion nace en 947_cuentas_demo.sql (datos de ejemplo). Revertir
-- solo quita la columna; las cuentas que sean personal quedan como
-- usuarios comunes, que es el estado anterior a la migracion.

DROP INDEX IF EXISTS ix_users_staff;
ALTER TABLE users DROP COLUMN IF EXISTS is_staff;

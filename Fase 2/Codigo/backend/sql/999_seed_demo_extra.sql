-- AgeCare — Datos de demostracion (SOLO DESARROLLO)
-- 999_seed_demo_extra.sql — Retirado
-- MIGRACION IDEMPOTENTE
--
-- Este archivo sembraba un segundo circulo de cuidado (tres cuentas y tres
-- pacientes de relleno). La demostracion usa un solo circulo, completo, y el
-- segundo solo agregaba cuentas que habia que explicar. Se deja vacio en vez
-- de borrarlo para que las bases que ya lo aplicaron no lo vean como faltante;
-- 999_unico_circulo_demo.sql quita esas filas de las bases existentes.
SELECT 1;

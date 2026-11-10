-- AgeCare — Datos de demostracion (SOLO DESARROLLO)
-- 999_seed_demo_extra_habilitacion.sql — Tipo de cuenta y habilitacion del
-- circulo de 999_seed_demo_extra
-- MIGRACION IDEMPOTENTE
--
-- 999_seed_demo_extra crea sus cuentas sin tipo (quedan como 'family', el
-- valor por defecto de 934) y al medico sin habilitacion, con lo que el
-- backend le niega todo acceso clinico. Aqui se alinea el tipo de cada una
-- y se habilita al medico, igual que 935 con la cuenta de demo principal.
-- Corre despues de 999_seed_demo_extra por orden de nombre.

UPDATE users SET account_type = 'caregiver'
 WHERE id = 'b985337d-0c2f-40f7-8a64-ec1df8973aaf' AND account_type <> 'caregiver';

UPDATE users SET account_type = 'doctor'
 WHERE id = '4a3cfa1a-fdc5-4245-9935-9b902250d906' AND account_type <> 'doctor';

INSERT INTO doctor_profiles (user_id, license_number, specialty)
SELECT u.id, 'RNPI-DEMO-0002', 'Medicina general'
  FROM users u
 WHERE u.id = '4a3cfa1a-fdc5-4245-9935-9b902250d906'
ON CONFLICT (user_id) DO NOTHING;

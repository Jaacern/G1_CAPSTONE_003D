-- AgeCare — Datos de demostracion (SOLO DESARROLLO)
-- 935_seed_medico_demo.sql — Una cuenta de medico habilitada para probar
-- MIGRACION IDEMPOTENTE
-- SEMILLA
-- Datos de ejemplo, no un cambio de esquema. Por eso no lleva revert
-- en sql/revertir/: deshacerla seria borrar datos de demostracion, que
-- es otra cosa que deshacer una migracion (RNF-24).
--
-- El seed principal no traia ningun medico, asi que la vista del medico no se
-- podia probar. Desde 934 un medico solo opera si esta habilitado, por lo que
-- aqui se crea la cuenta Y su habilitacion. Usa el mismo hash que las demas
-- cuentas de prueba (clave agecare123).
-- En produccion esta fila se borra o se le cambia la clave antes de salir.

INSERT INTO users (email, password_hash, first_name, last_name, phone, locale, account_type)
VALUES ('doctora@agecare.cl',
        '$2b$12$sOwnF0GBHVfW/6AuaTTIoez598bSRvAjjd.MhockXbT6sCX1.v4Xe',
        'Carolina', 'Soto', '+56922223333', 'es', 'doctor')
ON CONFLICT DO NOTHING;

-- Si la cuenta ya existia (creada a mano antes de 934), se alinea su tipo.
UPDATE users SET account_type = 'doctor'
 WHERE lower(email) = 'doctora@agecare.cl' AND account_type <> 'doctor';

INSERT INTO doctor_profiles (user_id, license_number, specialty)
SELECT u.id, 'RNPI-DEMO-0001', 'Medicina general'
  FROM users u
 WHERE lower(u.email) = 'doctora@agecare.cl'
ON CONFLICT (user_id) DO NOTHING;

-- Medica tratante de la paciente de demostracion (Elena).
INSERT INTO patient_members (patient_id, user_id, role, is_owner)
SELECT '33333333-3333-4333-8333-333333333333', u.id, 'doctor', false
  FROM users u
 WHERE lower(u.email) = 'doctora@agecare.cl'
   AND EXISTS (SELECT 1 FROM patients p
                WHERE p.id = '33333333-3333-4333-8333-333333333333')
ON CONFLICT (patient_id, user_id) DO UPDATE
   SET role = 'doctor', removed_at = NULL;

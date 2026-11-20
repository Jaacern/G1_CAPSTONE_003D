-- Revierte 934_tipo_cuenta_y_medicos_verificados.sql
--
-- PIERDE DATOS, y bastante:
--   - Desaparecen las habilitaciones de medico y los codigos de alta. Un
--     medico habilitado deja de poder operar como tal.
--   - Desaparece el tipo de cuenta de cada usuario. Se puede volver a
--     deducir de patient_members, que es de donde salio la primera vez.
--   - Desaparecen el segundo nombre y el segundo apellido de los pacientes.
--     full_name vuelve a ser una columna comun y se rearma con el primer
--     nombre y el primer apellido, asi que un paciente que tenia los cuatro
--     queda con dos.

DROP INDEX IF EXISTS ux_doctor_enrollments_token;
DROP TABLE IF EXISTS doctor_enrollments;

DROP INDEX IF EXISTS ux_doctor_profiles_license;
DROP TABLE IF EXISTS doctor_profiles;

ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_account_type;
ALTER TABLE users DROP COLUMN IF EXISTS account_type;

-- Los nombres del paciente vuelven a como estaban: una sola columna comun.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'patients'
           AND column_name = 'second_name'
    ) THEN
        DROP INDEX IF EXISTS ix_patients_full_name;
        -- Primero la generada, que depende de las otras dos.
        ALTER TABLE patients DROP COLUMN full_name;
        ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_second_name;
        ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_second_last_name;
        ALTER TABLE patients DROP COLUMN second_name;
        ALTER TABLE patients DROP COLUMN second_last_name;

        ALTER TABLE patients ADD COLUMN full_name varchar(250);
        UPDATE patients SET full_name = first_name || ' ' || last_name;
        ALTER TABLE patients ALTER COLUMN full_name SET NOT NULL;
        CREATE INDEX ix_patients_full_name
            ON patients (lower(full_name)) WHERE deleted_at IS NULL;
    END IF;
END $$;

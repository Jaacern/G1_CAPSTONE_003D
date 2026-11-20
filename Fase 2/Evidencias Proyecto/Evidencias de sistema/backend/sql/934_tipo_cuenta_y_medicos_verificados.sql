-- AgeCare — Identidad y acceso
-- 934_tipo_cuenta_y_medicos_verificados.sql
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--   1. El registro no guardaba que tipo de persona se estaba registrando. Una
--      cuenta nueva sin invitacion quedaba sin ningun rol, y la aplicacion
--      rellenaba el hueco asumiendo "familiar".
--   2. El rol 'doctor' lo podia dar cualquiera: el familiar administrador
--      invita "como medico" a un correo cualquiera y quien acepta pasa a poder
--      crear tratamientos y recetas. En una aplicacion de salud eso es un
--      riesgo clinico real, no solo de permisos.
--
-- COMO QUEDA
--   * users.account_type: que es la persona para la plataforma. Es distinto de
--     patient_members.role, que sigue siendo el rol DE LA RELACION con un
--     paciente. Se necesita porque quien aun no pertenece a ningun circulo
--     (una cuidadora recien registrada) igual tiene que ver su propia vista.
--   * doctor_profiles: un medico solo es medico si el personal de la empresa
--     lo habilito con su numero de registro profesional. Nadie se auto-declara.
--   * doctor_enrollments: la habilitacion se hace con un codigo de un solo uso
--     ligado a un correo. El personal nunca conoce la contrasena del medico.

-- ---------------------------------------------------------------------
-- 1. Tipo de cuenta
-- ---------------------------------------------------------------------
-- Solo en la primera ejecucion: el relleno se deduce de las membresias que ya
-- existen, y repetirlo mas tarde pisaria el tipo que alguien eligio al
-- registrarse.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'users'
           AND column_name = 'account_type'
    ) THEN
        ALTER TABLE users
            ADD COLUMN account_type varchar(10) NOT NULL DEFAULT 'family';

        UPDATE users u
           SET account_type = CASE
                 WHEN EXISTS (SELECT 1 FROM patient_members pm
                               WHERE pm.user_id = u.id AND pm.role = 'doctor')
                      THEN 'doctor'
                 WHEN EXISTS (SELECT 1 FROM patient_members pm
                               WHERE pm.user_id = u.id AND pm.role = 'elder')
                      THEN 'elder'
                 WHEN EXISTS (SELECT 1 FROM patient_members pm
                               WHERE pm.user_id = u.id AND pm.role = 'caregiver')
                  AND NOT EXISTS (SELECT 1 FROM patient_members pm
                               WHERE pm.user_id = u.id AND pm.role = 'family')
                      THEN 'caregiver'
                 ELSE 'family'
               END;
    END IF;
END $$;

ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_account_type;
ALTER TABLE users ADD CONSTRAINT ck_users_account_type
    CHECK (account_type IN ('family', 'caregiver', 'doctor', 'elder'));

COMMENT ON COLUMN users.account_type IS
    'Tipo de persona para la plataforma: family | caregiver | doctor | elder. Se elige al registrarse (solo family o caregiver); doctor exige habilitacion del personal (doctor_profiles); elder lo crea la familia. NO reemplaza patient_members.role, que es el rol de la relacion con cada paciente.';

-- ---------------------------------------------------------------------
-- 2. Medicos habilitados
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS doctor_profiles (
    user_id        uuid         PRIMARY KEY,
    license_number varchar(30)  NOT NULL,
    specialty      varchar(60),
    verified_at    timestamptz  NOT NULL DEFAULT now(),
    verified_by    uuid,
    revoked_at     timestamptz,
    revoked_reason varchar(200),
    created_at     timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_doctor_profiles_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_doctor_profiles_verified_by
        FOREIGN KEY (verified_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT ck_doctor_profiles_license
        CHECK (char_length(btrim(license_number)) >= 3)
);

-- Un mismo numero de registro profesional no puede estar en dos cuentas
-- vigentes: evita que dos personas operen con la misma habilitacion.
CREATE UNIQUE INDEX IF NOT EXISTS ux_doctor_profiles_license
    ON doctor_profiles (upper(license_number)) WHERE revoked_at IS NULL;

COMMENT ON TABLE doctor_profiles IS
    'Medicos habilitados por el personal de la empresa. Sin fila vigente (revoked_at NULL) una cuenta no puede operar con el rol doctor sobre ningun paciente, aunque tenga la membresia.';
COMMENT ON COLUMN doctor_profiles.license_number IS
    'Numero de registro profesional (Registro Nacional de Prestadores Individuales de la Superintendencia de Salud). Lo verifica una persona del personal antes de crear la habilitacion.';
COMMENT ON COLUMN doctor_profiles.verified_by IS
    'Persona del personal que verifico el registro.';

-- ---------------------------------------------------------------------
-- 3. Codigos de habilitacion (un solo uso, ligados a un correo)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS doctor_enrollments (
    id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    email          varchar(254) NOT NULL,
    license_number varchar(30)  NOT NULL,
    specialty      varchar(60),
    token_hash     char(64)     NOT NULL,
    created_by     uuid         NOT NULL,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    expires_at     timestamptz  NOT NULL,
    accepted_at    timestamptz,
    accepted_by    uuid,
    revoked_at     timestamptz,

    CONSTRAINT fk_doctor_enrollments_created_by
        FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_doctor_enrollments_accepted_by
        FOREIGN KEY (accepted_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT ck_doctor_enrollments_license
        CHECK (char_length(btrim(license_number)) >= 3)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_doctor_enrollments_token
    ON doctor_enrollments (token_hash);

COMMENT ON TABLE doctor_enrollments IS
    'Codigos con los que un medico crea su cuenta. Los emite el personal tras verificar el registro profesional. Se guarda solo el hash del codigo.';

-- ---------------------------------------------------------------------
-- 4. Identidad completa del paciente
-- ---------------------------------------------------------------------
-- Segundo nombre y segundo apellido, separados (el modelo guardaba "nombre(s)"
-- y "apellido(s)" en dos columnas). full_name es GENERATED y PostgreSQL 16 no
-- permite cambiar su expresion: se recrea, junto con su unico dependiente (el
-- indice de busqueda). Solo la primera vez.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'patients'
           AND column_name = 'second_name'
    ) THEN
        DROP INDEX IF EXISTS ix_patients_full_name;
        ALTER TABLE patients DROP COLUMN full_name;

        ALTER TABLE patients
            ADD COLUMN second_name      varchar(60),
            ADD COLUMN second_last_name varchar(60);

        ALTER TABLE patients
            ADD COLUMN full_name varchar(250) GENERATED ALWAYS AS (
                first_name
                || COALESCE(' ' || second_name, '')
                || ' ' || last_name
                || COALESCE(' ' || second_last_name, '')
            ) STORED;

        CREATE INDEX ix_patients_full_name
            ON patients (lower(full_name)) WHERE deleted_at IS NULL;
    END IF;
END $$;

ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_second_name;
ALTER TABLE patients ADD CONSTRAINT ck_patients_second_name
    CHECK (second_name IS NULL OR char_length(btrim(second_name)) >= 1);
ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_second_last_name;
ALTER TABLE patients ADD CONSTRAINT ck_patients_second_last_name
    CHECK (second_last_name IS NULL OR char_length(btrim(second_last_name)) >= 1);

COMMENT ON COLUMN patients.second_name IS
    'Segundo nombre. Opcional: no toda persona lo tiene.';
COMMENT ON COLUMN patients.second_last_name IS
    'Segundo apellido (materno). Opcional: no toda persona lo tiene.';
COMMENT ON COLUMN patients.full_name IS
    'Columna generada: nombre, segundo nombre, apellido y segundo apellido, sin huecos. Solo lectura.';

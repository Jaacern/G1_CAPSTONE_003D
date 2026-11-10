-- AgeCare — Identidad de las cuentas
-- 946_identidad_usuarios.sql — Nombre en cuatro partes y RUT en users
-- MIGRACION IDEMPOTENTE
--
-- POR QUE
--   users guardaba "nombre(s)" y "apellido(s)" en dos columnas, igual que
--   patients antes de 934. Una cuidadora que se publica en el marketplace y
--   entra a la casa de un adulto mayor tiene que poder identificarse sin
--   ambigüedad: nombre, segundo nombre, apellido paterno, apellido materno y
--   RUT. El RUT vive en users y no en el perfil de cuidadora porque es de la
--   persona, no del rol, y una persona tiene uno solo.
--
--   Es opcional en la tabla: el familiar no lo necesita. La API lo exige
--   para registrarse como cuidador(a) y para publicar el perfil.

-- ---------------------------------------------------------------------
-- Segundo nombre y segundo apellido. full_name es GENERATED y PostgreSQL 16
-- no permite cambiar su expresión: se recrea (no tiene dependientes).
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'users'
           AND column_name = 'second_name'
    ) THEN
        ALTER TABLE users DROP COLUMN full_name;

        ALTER TABLE users
            ADD COLUMN second_name      varchar(60),
            ADD COLUMN second_last_name varchar(60);

        ALTER TABLE users
            ADD COLUMN full_name varchar(250) GENERATED ALWAYS AS (
                first_name
                || COALESCE(' ' || second_name, '')
                || ' ' || last_name
                || COALESCE(' ' || second_last_name, '')
            ) STORED;
    END IF;
END $$;

ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_second_name;
ALTER TABLE users ADD CONSTRAINT ck_users_second_name
    CHECK (second_name IS NULL OR char_length(btrim(second_name)) >= 1);
ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_second_last_name;
ALTER TABLE users ADD CONSTRAINT ck_users_second_last_name
    CHECK (second_last_name IS NULL OR char_length(btrim(second_last_name)) >= 1);

-- ---------------------------------------------------------------------
-- RUT, con el mismo resguardo que patients (915): el dígito se verifica en
-- el motor y un RUT no puede pertenecer a dos cuentas.
-- ---------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS rut_number integer;
ALTER TABLE users ADD COLUMN IF NOT EXISTS rut_dv     char(1);

ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_rut_number;
ALTER TABLE users ADD CONSTRAINT ck_users_rut_number
    CHECK (rut_number IS NULL OR rut_number BETWEEN 1000000 AND 99999999);
ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_rut_completo;
ALTER TABLE users ADD CONSTRAINT ck_users_rut_completo
    CHECK ((rut_number IS NULL) = (rut_dv IS NULL));
ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_rut_dv_correcto;
ALTER TABLE users ADD CONSTRAINT ck_users_rut_dv_correcto
    CHECK (rut_number IS NULL OR rut_dv = rut_digito_verificador(rut_number));

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_rut
    ON users (rut_number) WHERE rut_number IS NOT NULL;

COMMENT ON COLUMN users.second_name IS
    'Segundo nombre. Opcional: no toda persona lo tiene.';
COMMENT ON COLUMN users.second_last_name IS
    'Segundo apellido (materno). Opcional: no toda persona lo tiene.';
COMMENT ON COLUMN users.full_name IS
    'Columna generada: nombre, segundo nombre, apellido y segundo apellido, sin huecos. Solo lectura.';
COMMENT ON COLUMN users.rut_number IS
    'Número del RUT, sin dígito verificador. Opcional en la tabla; la API lo exige a la cuidadora. Único entre cuentas.';
COMMENT ON COLUMN users.rut_dv IS
    'Dígito verificador del RUT. Derivado de rut_number por el módulo 11 y verificado con un CHECK.';

-- ---------------------------------------------------------------------
-- Datos de demostración: la cuidadora del seed (Rosa) con su identidad
-- completa. El dígito lo calcula la misma función del CHECK.
-- ---------------------------------------------------------------------
UPDATE users
   SET second_last_name = COALESCE(second_last_name, 'Díaz'),
       rut_number = 15234567,
       rut_dv     = rut_digito_verificador(15234567)
 WHERE id = '22222222-2222-4222-8222-222222222222'
   AND rut_number IS NULL
   AND NOT EXISTS (SELECT 1 FROM users WHERE rut_number = 15234567);

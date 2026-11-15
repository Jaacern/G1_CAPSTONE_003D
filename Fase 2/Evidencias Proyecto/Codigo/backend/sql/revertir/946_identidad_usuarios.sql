-- Revierte 946_identidad_usuarios.sql
--
-- PIERDE DATOS: desaparecen el segundo nombre, el segundo apellido y el RUT
-- de todos los usuarios. full_name vuelve a ser una columna comun y se
-- rearma con el primer nombre y el primer apellido, asi que quien tenia los
-- cuatro queda con dos.

ALTER TABLE users DROP COLUMN IF EXISTS rut_dv;
ALTER TABLE users DROP COLUMN IF EXISTS rut_number;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'users'
           AND column_name = 'second_name'
    ) THEN
        ALTER TABLE users DROP COLUMN full_name;
        ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_second_name;
        ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_second_last_name;
        ALTER TABLE users DROP COLUMN second_name;
        ALTER TABLE users DROP COLUMN second_last_name;

        ALTER TABLE users ADD COLUMN full_name varchar(250);
        UPDATE users SET full_name = first_name || ' ' || last_name;
        ALTER TABLE users ALTER COLUMN full_name SET NOT NULL;
    END IF;
END $$;

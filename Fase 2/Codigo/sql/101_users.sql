-- AgeCare — Bloque 1: Identidad y acceso


CREATE TABLE users(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email varchar (254) NOT NULL,
    password_hash varchar(255) NOT NULL,
    full_name varchar(120) NOT NULL,
    phone varchar(16),
    avatar_url text,
    locale varchar(5) NOT NULL DEFAULT 'es',
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_At timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,

    CONSTRAINT ck_users_locale
        CHECK (locale IN ('es', 'en')),
        CONSTRAINT ck_users_full_name_min
            CHECK (char_length(full_name) >= 2)
);

-- Un mismo correo no puede usarse dos veces, aunque se escriba distinto en mayúsculas.
-- Ademas aceleramos las consultas en el Login

CREATE UNIQUE INDEX ux_users_email_lower ON users (lower(email));


--el update_at se mantiene solo ais cada vez que una fila se actualice, antes de guardarla
--se pondra el update_at en la hora que se actualizo
CREATE TRIGGER tg_users_update_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

--diccionario de datos en español, dentro de la propia bd para DUOC
COMMENT ON TABLE  users IS
    'Cuentas de usuario. El rol NO vive acá: un usuario puede tener roles distintos sobre distintos pacientes, y eso se resuelve en patient_members.';
    COMMENT ON COLUMN users.id IS
    'Identificador interno. UUID generado por la base.';
COMMENT ON COLUMN users.avatar_url IS
    'URL de la foto de perfil. Opcional.';
COMMENT ON COLUMN users.created_at IS
    'Fecha de creación del registro.';
COMMENT ON COLUMN users.updated_at IS
    'Fecha de última modificación. La mantiene el trigger tg_users_updated_at.';
COMMENT ON COLUMN users.email IS
    'Correo de acceso. Unicidad garantizada por ux_users_email_lower, sin distinguir mayúsculas.';
COMMENT ON COLUMN users.password_hash IS
    'Hash argon2 o bcrypt. Nunca la contraseña en claro. Largo holgado porque el algoritmo aún no está decidido.';
COMMENT ON COLUMN users.full_name IS
    'Nombre completo, 2 a 120 caracteres. Se evaluó separarlo y se mantuvo unido por contrato con la API.';
COMMENT ON COLUMN users.phone IS
    'Teléfono en formato E.164, opcional.';
COMMENT ON COLUMN users.locale IS
    'Idioma preferido de la interfaz. es | en.';
COMMENT ON COLUMN users.is_active IS
    'false = cuenta desactivada por soporte. Ticket AGE-208.';
COMMENT ON COLUMN users.deleted_at IS
    'Baja lógica para la eliminación de cuenta. Ticket AGE-1007, requisito de Google Play. NULL = vigente.';


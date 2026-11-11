-- AgeCare — Tokens de recuperación de contraseña
-- 964_password_reset_tokens.sql — RF-05
--
-- Cierra el stub de /auth/password/recovery + /auth/password/reset.
-- Los dos endpoints existían pero sin tabla de tokens no podían validar nada.
--
-- DISEÑO DE SEGURIDAD
--   · El token en claro solo existe en el correo que sale al usuario.
--     Aquí se guarda el hash SHA-256, igual que refresh_tokens y
--     device_link_codes. Quien lea la base no puede usarlo para resetear.
--   · Vence en 30 minutos (configurable en system_parameters).
--   · Un solo token activo por usuario: pedir uno nuevo invalida el anterior.
--     Esto evita que se acumulen tokens válidos si el usuario pide varios.
--   · Se marca como usado (used_at) en vez de borrado para tener trazabilidad.
--   · Un índice parcial acelera la búsqueda por hash entre los no usados.

CREATE TABLE IF NOT EXISTS password_reset_tokens (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  varchar(64) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz,

    CONSTRAINT uq_password_reset_tokens_hash UNIQUE (token_hash),
    CONSTRAINT ck_password_reset_tokens_vence
        CHECK (expires_at > created_at)
);

COMMENT ON TABLE password_reset_tokens IS
    'Tokens de un solo uso para recuperar la contraseña (RF-05). Se guarda el hash; el token en claro solo viaja en el correo.';
COMMENT ON COLUMN password_reset_tokens.token_hash IS
    'SHA-256 del token en claro. Nunca se guarda el token en claro.';
COMMENT ON COLUMN password_reset_tokens.used_at IS
    'Momento en que se usó. NULL = aún válido (si tampoco venció).';

-- Búsqueda rápida al validar un token recibido.
CREATE INDEX IF NOT EXISTS ix_password_reset_tokens_hash_activo
    ON password_reset_tokens (token_hash)
    WHERE used_at IS NULL;

-- Un usuario no debería acumular muchos tokens activos; solo el último sirve.
-- El índice ayuda a limpiar el anterior al crear uno nuevo.
CREATE INDEX IF NOT EXISTS ix_password_reset_tokens_user
    ON password_reset_tokens (user_id, created_at DESC);

-- Parámetro que controla la ventana de validez (en minutos).
-- Lo lee el backend; modificarlo en esta tabla es suficiente.
INSERT INTO system_parameters (key, value, description)
VALUES (
    'password_reset_expire_minutes',
    '30',
    'Minutos de validez del enlace de recuperación de contraseña (RF-05).'
)
ON CONFLICT (key) DO NOTHING;

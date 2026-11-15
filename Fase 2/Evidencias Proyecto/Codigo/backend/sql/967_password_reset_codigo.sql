-- AgeCare — Recuperación de contraseña con código
-- 967_password_reset_codigo.sql — RF-05
-- MIGRACION IDEMPOTENTE
--
-- QUÉ CAMBIA RESPECTO A 964
--     964 guardaba un token largo pensado para un enlace profundo
--     (agecare://reset-password?token=...). La app no tiene manejo de ese
--     enlace, y quien recupera la contraseña lo hace casi siempre desde el
--     mismo teléfono, donde copiar un código de 6 dígitos es más simple que
--     abrir un enlace. Ahora el correo lleva un CÓDIGO de 6 dígitos.
--
-- POR QUÉ HACE FALTA attempts
--     Un código de 6 dígitos tiene un millón de combinaciones. Sin tope de
--     intentos, alguien que conoce el correo de la víctima puede probarlas
--     todas dentro de la ventana de validez. Cada código admite como máximo
--     password_reset_max_attempts equivocaciones; al llegar al tope queda
--     inutilizado y hay que pedir uno nuevo.
--
-- token_hash SIGUE SIENDO UNIQUE
--     El hash ya no es sha256(código), porque dos usuarios podrían recibir el
--     mismo código y chocarían. Ahora es sha256(user_id || ':' || código).
--     Las filas anteriores (token largo) quedan sin efecto práctico: vencen
--     solas y ningún código de 6 dígitos coincide con ellas.

ALTER TABLE password_reset_tokens
    ADD COLUMN IF NOT EXISTS attempts smallint NOT NULL DEFAULT 0;

ALTER TABLE password_reset_tokens
    DROP CONSTRAINT IF EXISTS ck_password_reset_tokens_attempts;
ALTER TABLE password_reset_tokens
    ADD CONSTRAINT ck_password_reset_tokens_attempts CHECK (attempts >= 0);

COMMENT ON COLUMN password_reset_tokens.attempts IS
    'Códigos equivocados ingresados contra esta fila. Al llegar a password_reset_max_attempts la fila se marca usada.';
COMMENT ON COLUMN password_reset_tokens.token_hash IS
    'SHA-256 de "user_id:código". El código en claro solo viaja en el correo.';

INSERT INTO system_parameters (key, value, description)
VALUES (
    'password_reset_max_attempts',
    '5',
    'Intentos fallidos permitidos por código de recuperación antes de invalidarlo (RF-05).'
)
ON CONFLICT (key) DO NOTHING;

UPDATE system_parameters
   SET description = 'Minutos de validez del código de recuperación de contraseña (RF-05).'
 WHERE key = 'password_reset_expire_minutes';

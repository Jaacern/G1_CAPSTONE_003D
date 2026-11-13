-- Revierte 967_password_reset_codigo.sql
--
-- PIERDE DATOS: se olvida cuantos intentos fallidos llevaba cada codigo de
-- recuperacion en vuelo. Sin esa cuenta, un codigo que estaba por
-- invalidarse vuelve a admitir intentos. Los codigos viven minutos, asi que
-- la ventana es corta.

ALTER TABLE password_reset_tokens
    DROP CONSTRAINT IF EXISTS ck_password_reset_tokens_attempts;
ALTER TABLE password_reset_tokens DROP COLUMN IF EXISTS attempts;

DELETE FROM system_parameters WHERE key = 'password_reset_max_attempts';

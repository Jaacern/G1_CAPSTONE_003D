-- MIGRACION IDEMPOTENTE
-- AgeCare — Invitaciones con código de 6 dígitos
-- 961_invitations_codigo.sql
--
-- Contexto: la invitación al círculo de cuidado pasa de un token largo
-- (64 caracteres hex) a un código de 6 dígitos, que es lo que la app pide
-- y lo que se puede dictar por teléfono (ticket AGE-205). Se sigue guardando
-- solo el SHA-256 del código en token_hash, nunca el código en claro.
--
-- Dos índices del archivo 106 dejan de calzar con eso:
--
-- 1. ux_invitations_pending (patient_id, lower(email)) se pensó para
--    invitaciones por correo. El correo es opcional y la API lo guardaba
--    como '' cuando no venía, así que la SEGUNDA invitación sin correo al
--    mismo paciente chocaba con la primera y la API respondía 500. Se
--    permite que el correo sea NULL (sin correo = no hay correo, no un correo
--    vacío) y el índice solo mira las filas que sí tienen uno.
--
-- 2. ux_invitations_token era único sobre TODA la tabla. Con un token de
--    256 bits nunca se repetía; con un código de 6 dígitos (un millón de
--    valores) es normal que un código ya usado hace meses vuelva a salir.
--    Lo que importa es que no haya dos invitaciones PENDIENTES con el mismo
--    código, porque esas son las que se pueden canjear. Las aceptadas o
--    anuladas conservan su hash como historia y ya no compiten.
--
-- Repetible: cada sentencia deja el mismo resultado si se corre de nuevo.

ALTER TABLE invitations ALTER COLUMN email DROP NOT NULL;

UPDATE invitations SET email = NULL WHERE email = '';

DROP INDEX IF EXISTS ux_invitations_pending;
CREATE UNIQUE INDEX ux_invitations_pending
    ON invitations (patient_id, lower(email))
    WHERE accepted_at IS NULL AND revoked_at IS NULL AND email IS NOT NULL;

DROP INDEX IF EXISTS ux_invitations_token;
CREATE UNIQUE INDEX ux_invitations_token
    ON invitations (token_hash)
    WHERE accepted_at IS NULL AND revoked_at IS NULL;

COMMENT ON COLUMN invitations.email IS
    'Correo del invitado, opcional. NULL cuando el familiar comparte el código por otro medio. Sin clave foránea a users porque puede no existir aún.';
COMMENT ON COLUMN invitations.token_hash IS
    'SHA-256 del código de 6 dígitos de la invitación. Nunca en claro: ese código da acceso a un expediente clínico. Único solo entre las pendientes (ver ux_invitations_token).';

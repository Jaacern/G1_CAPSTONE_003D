-- Revierte 961_invitations_codigo.sql
--
-- Vuelve a exigir correo en toda invitacion. Las invitaciones por codigo,
-- que no tienen correo, quedarian fuera de esa regla, asi que se detiene
-- antes de tocar nada si hay alguna pendiente.

DO $$
DECLARE
    sin_correo int;
BEGIN
    SELECT count(*) INTO sin_correo
      FROM invitations
     WHERE email IS NULL
       AND accepted_at IS NULL AND revoked_at IS NULL;
    IF sin_correo > 0 THEN
        RAISE EXCEPTION
            'Hay % invitaciones pendientes sin correo, que es lo que esta '
            'migracion permitio. Revertir las dejaria invalidas. Revocalas o '
            'completales el correo y volve a intentar.', sin_correo;
    END IF;
END $$;

-- Las ya aceptadas o revocadas si se pueden completar: no se usan mas y el
-- NOT NULL necesita que ninguna fila quede nula.
UPDATE invitations SET email = '' WHERE email IS NULL;
ALTER TABLE invitations ALTER COLUMN email SET NOT NULL;

DROP INDEX IF EXISTS ux_invitations_pending;
CREATE UNIQUE INDEX ux_invitations_pending
    ON invitations (patient_id, lower(email))
    WHERE accepted_at IS NULL AND revoked_at IS NULL;

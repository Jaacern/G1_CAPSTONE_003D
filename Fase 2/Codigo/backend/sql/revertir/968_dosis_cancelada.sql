-- Revierte 968_dosis_cancelada.sql
--
-- Saca 'cancelled' de los estados que admite una toma y deja la lista como
-- la habia dejado la 931, con 'adverse' adentro.
--
-- NO BORRA NADA por su cuenta. Una toma cancelada es parte del expediente:
-- dice que esa toma dejo de corresponder y por que. Borrarla o cambiarle el
-- estado a mano son decisiones distintas y ninguna la puede tomar un revert.
-- Si las hay, se detiene y lo dice.

DO $$
DECLARE
    cuantas bigint;
BEGIN
    SELECT count(*) INTO cuantas
      FROM scheduled_doses WHERE status = 'cancelled';
    IF cuantas > 0 THEN
        RAISE EXCEPTION
            'Hay % tomas canceladas. Son parte del expediente y este revert '
            'no las toca solo. Decidi que hacer con ellas y volve a '
            'intentar.', cuantas;
    END IF;
END $$;

DROP INDEX IF EXISTS ix_scheduled_doses_cancelables;

ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_status;
ALTER TABLE scheduled_doses ADD CONSTRAINT ck_scheduled_doses_status CHECK (
    status IN ('pending', 'taken', 'skipped', 'postponed', 'missed', 'adverse')
);

COMMENT ON COLUMN scheduled_doses.status IS NULL;

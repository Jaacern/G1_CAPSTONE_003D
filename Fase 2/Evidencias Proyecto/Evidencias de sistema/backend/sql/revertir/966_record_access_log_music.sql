-- Revierte 966_record_access_log_music.sql
--
-- Saca 'music' de las secciones que el registro de accesos acepta y deja la
-- lista como la habia dejado la 962, con 'assistant' adentro.
--
-- NO BORRA NADA por su cuenta, por la misma razon que la 962: esas filas son
-- trazabilidad del expediente.

DO $$
DECLARE
    cuantas bigint;
BEGIN
    SELECT count(*) INTO cuantas
      FROM record_access_log WHERE section = 'music';
    IF cuantas > 0 THEN
        RAISE EXCEPTION
            'Hay % accesos anotados con la seccion music. Son trazabilidad '
            'del expediente y este revert no los borra solo. Decidi que '
            'hacer con ellos y volve a intentar.', cuantas;
    END IF;
END $$;

ALTER TABLE record_access_log
    DROP CONSTRAINT IF EXISTS ck_record_access_log_section;
ALTER TABLE record_access_log
    ADD CONSTRAINT ck_record_access_log_section CHECK (
        section IN ('profile','vitals','medications','doses','logbook',
                    'documents','alerts','chat','reports','members',
                    'assistant')
    );

-- Revierte 962_record_access_log_assistant.sql
--
-- Saca 'assistant' de las secciones que el registro de accesos acepta.
--
-- NO BORRA NADA por su cuenta. Si ya hay accesos anotados con esa seccion,
-- achicar el CHECK los dejaria fuera de la regla, y esas filas son la
-- trazabilidad de quien miro que expediente (RNF-14): no es algo que un
-- revert pueda decidir borrar solo. Se detiene y lo dice.
--
-- OJO CON EL ORDEN: la 966 agrego 'music' sobre esta misma lista. Hay que
-- revertir aquella primero.

DO $$
DECLARE
    cuantas bigint;
BEGIN
    SELECT count(*) INTO cuantas
      FROM record_access_log WHERE section = 'assistant';
    IF cuantas > 0 THEN
        RAISE EXCEPTION
            'Hay % accesos anotados con la seccion assistant. Son '
            'trazabilidad del expediente y este revert no los borra solo. '
            'Decidi que hacer con ellos y volve a intentar.', cuantas;
    END IF;
END $$;

ALTER TABLE record_access_log
    DROP CONSTRAINT IF EXISTS ck_record_access_log_section;
ALTER TABLE record_access_log
    ADD CONSTRAINT ck_record_access_log_section CHECK (
        section IN ('profile','vitals','medications','doses','logbook',
                    'documents','alerts','chat','reports','members')
    );

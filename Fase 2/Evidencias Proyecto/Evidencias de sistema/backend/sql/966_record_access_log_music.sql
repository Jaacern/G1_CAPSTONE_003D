-- AgeCare — Auditoria
-- 966_record_access_log_music.sql — Seccion 'music' en el registro de accesos
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--     acceso.py clasifica las lecturas de /music como seccion 'music', pero el
--     CHECK de record_access_log (ultima version en 962) no la admite. El
--     insert fallaba, registrar_acceso() captura el error para no romper la
--     consulta, y el resultado era una auditoria sin ninguna fila de musica
--     y sin ningun aviso.
--
-- POR QUE ES EXPEDIENTE
--     Las creaciones del Director Musical las hace el adulto mayor y las ve su
--     familia. Quien las escucha o las comparte es informacion de uso de una
--     persona, y RNF-14 pide saber quien consulto que.
--
-- La tabla esta particionada por mes. El CHECK se cambia en la tabla madre y
-- Postgres lo propaga a todas las particiones.

ALTER TABLE record_access_log
    DROP CONSTRAINT IF EXISTS ck_record_access_log_section;

ALTER TABLE record_access_log
    ADD CONSTRAINT ck_record_access_log_section CHECK (
        section IN ('profile','vitals','medications','doses','logbook',
                    'documents','alerts','chat','reports','members',
                    'assistant','music')
    );

COMMENT ON COLUMN record_access_log.section IS
    'Parte del expediente consultada: profile | vitals | medications | doses | logbook | documents | alerts | chat | reports | members | assistant | music. ''assistant'' es una pregunta al asistente de IA; ''music'' son las creaciones del Director Musical.';

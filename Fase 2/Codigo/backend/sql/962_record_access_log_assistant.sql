-- AgeCare — Auditoria
-- 962_record_access_log_assistant.sql — Seccion 'assistant' en el registro de accesos
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--     record_access_log (601) registra quien consulto que parte de un
--     expediente (RNF-14), y su CHECK enumera las secciones validas. El
--     asistente de IA no estaba: una pregunta al asistente no cabia en
--     ninguna.
--
--     Y es de los accesos que mas importa registrar. Abrir la pantalla de
--     vitales muestra los vitales. Preguntarle algo al asistente le entrega
--     al modelo, en nombre de esa persona, el perfil, los medicamentos, las
--     mediciones, la bitacora, las alertas y el texto de los documentos, todo
--     junto. Es la consulta mas amplia que se le puede hacer a un expediente.
--
-- POR QUE UNA SECCION PROPIA Y NO 'chat'
--     'chat' es la conversacion entre las personas del circulo. Registrar ahi
--     las preguntas al asistente mezclaria dos cosas que una auditoria
--     necesita distinguir: quien leyo los mensajes de la familia y quien le
--     pidio a un modelo que leyera el expediente entero.
--
-- La tabla esta particionada por mes. El CHECK se cambia en la tabla madre y
-- Postgres lo propaga a todas las particiones, las que existen y las que se
-- creen despues.

ALTER TABLE record_access_log
    DROP CONSTRAINT IF EXISTS ck_record_access_log_section;

ALTER TABLE record_access_log
    ADD CONSTRAINT ck_record_access_log_section CHECK (
        section IN ('profile','vitals','medications','doses','logbook',
                    'documents','alerts','chat','reports','members',
                    'assistant')
    );

COMMENT ON COLUMN record_access_log.section IS
    'Parte del expediente consultada: profile | vitals | medications | doses | logbook | documents | alerts | chat | reports | members | assistant. ''assistant'' es una pregunta al asistente de IA, que lee el expediente completo en nombre del usuario.';

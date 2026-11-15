-- AgeCare — Soporte WebSocket para chat en tiempo real
-- 965_chat_websocket.sql — RF-54
--
-- El chat ya existe (802_messages.sql, 803_message_receipts.sql).
-- Lo que faltaba era el canal en tiempo real: los mensajes llegaban solo
-- al recargar (polling). Esta migración agrega la infraestructura de base
-- que el backend necesita para notificar vía WebSocket.
--
-- DISEÑO
--   · Se usa LISTEN / NOTIFY de PostgreSQL: cuando llega un mensaje nuevo
--     la base avisa a todos los workers que tengan una conexión abierta.
--     Sin Redis, sin Celery, sin servicio extra.
--   · El trigger dispara el NOTIFY. El backend escucha en una conexión
--     dedicada y reenvía el payload al WebSocket del cliente.
--   · El payload lleva conversation_id y patient_id para que el backend
--     sepa a qué conexión entregar el aviso.

-- Función que dispara el NOTIFY con el id de la conversación afectada.
CREATE OR REPLACE FUNCTION notify_new_message()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Canal: 'chat_<conversation_id>'.
    -- Payload: JSON con los ids necesarios para que el backend identifique
    -- la conversación y al remitente sin consulta adicional.
    PERFORM pg_notify(
        'chat_new_message',
        json_build_object(
            'conversation_id', NEW.conversation_id,
            'message_id',      NEW.id,
            'sender_id',       NEW.sender_id,
            'kind',            NEW.kind,
            'created_at',      to_char(NEW.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')
        )::text
    );
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION notify_new_message IS
    'Dispara un NOTIFY cuando se inserta un mensaje nuevo. El backend lo escucha y lo reenvía a los WebSockets conectados. RF-54.';

-- Trigger sobre messages.
DROP TRIGGER IF EXISTS tg_messages_notify ON messages;
CREATE TRIGGER tg_messages_notify
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION notify_new_message();

-- Tabla de sesiones WebSocket activas.
-- Permite que el backend sepa qué usuarios tienen una conexión abierta
-- en qué worker, para no enviar a conexiones muertas y para limpieza.
-- Los workers borran sus filas al arrancar (en caso de que hayan quedado
-- huérfanas por una caída) y al cerrar el WebSocket.
CREATE TABLE IF NOT EXISTS chat_ws_sessions (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    patient_id      uuid        NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    worker_pid      integer     NOT NULL,
    connected_at    timestamptz NOT NULL DEFAULT now(),
    last_ping_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_chat_ws_sessions_user_patient
        UNIQUE (user_id, patient_id)
);

COMMENT ON TABLE chat_ws_sessions IS
    'Sesiones WebSocket activas del chat. Un worker la registra al conectar y la borra al desconectar. RF-54.';

CREATE INDEX IF NOT EXISTS ix_chat_ws_sessions_patient
    ON chat_ws_sessions (patient_id);

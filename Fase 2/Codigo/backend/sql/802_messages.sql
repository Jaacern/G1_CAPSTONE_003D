CREATE TABLE messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE RESTRICT,
    sender_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    kind VARCHAR(20) NOT NULL DEFAULT 'text',
    body TEXT,
    file_id UUID REFERENCES files(id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_messages_kind CHECK (kind IN ('text', 'voice', 'photo')),
    CONSTRAINT chk_messages_content CHECK (
        (kind = 'text' AND btrim(body) <> '') OR 
        (kind IN ('voice', 'photo') AND file_id IS NOT NULL)
    )
);

COMMENT ON TABLE messages IS 'Mensajes individuales (texto, voz, foto) transmitidos en una conversación.';
COMMENT ON COLUMN messages.id IS 'Identificador único del mensaje.';
COMMENT ON COLUMN messages.conversation_id IS 'Conversación a la que pertenece el mensaje.';
COMMENT ON COLUMN messages.sender_id IS 'Usuario autor del mensaje.';
COMMENT ON COLUMN messages.kind IS 'Formato del mensaje: text, voice, photo.';
COMMENT ON COLUMN messages.body IS 'Contenido textual del mensaje (no vacío tras trim).';
COMMENT ON COLUMN messages.file_id IS 'Referencia al archivo adjunto en la tabla files (para voz o foto).';
COMMENT ON COLUMN messages.created_at IS 'Fecha y hora de envío del mensaje.';

CREATE INDEX ix_messages_conversation_created 
ON messages(conversation_id, created_at ASC);
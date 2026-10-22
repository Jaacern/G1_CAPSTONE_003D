CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
    type VARCHAR(20) NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE RESTRICT, -- NULL para 'human' global, obligatorio para 'assistant' individual
    last_message_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_conversations_type CHECK (type IN ('human', 'assistant')),
    CONSTRAINT chk_conversations_user_type CHECK (
        (type = 'human' AND user_id IS NULL) OR 
        (type = 'assistant' AND user_id IS NOT NULL)
    ),
    CONSTRAINT uq_conversations_id_type UNIQUE (id, type)
);

CREATE UNIQUE INDEX ux_conversations_human 
ON conversations(patient_id) WHERE type = 'human';

CREATE UNIQUE INDEX ux_conversations_assistant 
ON conversations(patient_id, user_id) WHERE type = 'assistant';

COMMENT ON TABLE conversations IS 'Hilos de conversación asociados a un paciente (chat del círculo de cuidado e hilos individuales del asistente IA).';
COMMENT ON COLUMN conversations.id IS 'Identificador único de la conversación.';
COMMENT ON COLUMN conversations.patient_id IS 'Paciente al que pertenece la conversación.';
COMMENT ON COLUMN conversations.type IS 'Tipo de canal de conversación: human (círculo de cuidado) o assistant (asistente IA).';
COMMENT ON COLUMN conversations.user_id IS 'Usuario propietario del hilo de asistente IA. Nulo para el chat humano global.';
COMMENT ON COLUMN conversations.last_message_at IS 'Fecha y hora del último mensaje para ordenamiento de la bandeja.';
COMMENT ON COLUMN conversations.created_at IS 'Fecha y hora de creación del registro.';
COMMENT ON COLUMN conversations.updated_at IS 'Fecha y hora de última actualización del registro.';

CREATE INDEX ix_conversations_patient_last_msg 
ON conversations(patient_id, last_message_at DESC);

CREATE TRIGGER tg_conversations_updated_at
BEFORE UPDATE ON conversations
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
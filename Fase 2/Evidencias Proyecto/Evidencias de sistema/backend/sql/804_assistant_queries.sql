CREATE TABLE assistant_queries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    conversation_type VARCHAR(20) NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    frozen_role_name VARCHAR(50) NOT NULL,
    query_text TEXT NOT NULL,
    response_text TEXT NOT NULL,
    latency_ms INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_assistant_queries_frozen_role CHECK (frozen_role_name IN ('family', 'caregiver', 'doctor', 'elder')),
    CONSTRAINT chk_assistant_queries_latency CHECK (latency_ms >= 0),
    CONSTRAINT chk_assistant_queries_tipo CHECK (conversation_type IN ('human', 'assistant')), -- Soporta RF-58 (invocar dentro del chat humano)
    CONSTRAINT fk_assistant_queries_conversation
        FOREIGN KEY (conversation_id, conversation_type) 
        REFERENCES conversations(id, type) ON DELETE RESTRICT
);

COMMENT ON TABLE assistant_queries IS 'Registro de consultas realizadas al asistente de IA y sus respuestas.';
COMMENT ON COLUMN assistant_queries.id IS 'Identificador único de la consulta al asistente.';
COMMENT ON COLUMN assistant_queries.conversation_id IS 'Conversación asociada donde se originó la consulta.';
COMMENT ON COLUMN assistant_queries.conversation_type IS 'Tipo de conversación donde se realizó la consulta (human o assistant).';
COMMENT ON COLUMN assistant_queries.user_id IS 'Usuario que realiza la consulta.';
COMMENT ON COLUMN assistant_queries.frozen_role_name IS 'Rol del usuario al momento de consultar (family, caregiver, doctor, elder).';
COMMENT ON COLUMN assistant_queries.query_text IS 'Texto ingresado por el usuario.';
COMMENT ON COLUMN assistant_queries.response_text IS 'Respuesta generada por el asistente de IA.';
COMMENT ON COLUMN assistant_queries.latency_ms IS 'Tiempo de respuesta del asistente en milisegundos.';
COMMENT ON COLUMN assistant_queries.created_at IS 'Fecha y hora de la consulta.';

CREATE INDEX ix_assistant_queries_user 
ON assistant_queries(user_id, created_at DESC);

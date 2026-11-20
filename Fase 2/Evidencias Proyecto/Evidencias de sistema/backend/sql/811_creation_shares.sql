CREATE TABLE creation_shares (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    music_creation_id UUID NOT NULL REFERENCES music_creations(id) ON DELETE RESTRICT,
    shared_with_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uq_creation_shares_creation_user UNIQUE (music_creation_id, shared_with_user_id)
);

COMMENT ON TABLE creation_shares IS 'Compartición explícita de creaciones musicales con miembros específicos del círculo de cuidado.';
COMMENT ON COLUMN creation_shares.id IS 'Identificador único del registro de compartido.';
COMMENT ON COLUMN creation_shares.music_creation_id IS 'Creación musical que se comparte.';
COMMENT ON COLUMN creation_shares.shared_with_user_id IS 'Miembro del círculo de cuidado destinatario.';
COMMENT ON COLUMN creation_shares.created_at IS 'Fecha y hora de compartición.';

CREATE INDEX ix_creation_shares_user 
ON creation_shares(shared_with_user_id);
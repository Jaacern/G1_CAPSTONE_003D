CREATE TABLE photo_reactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    photo_id UUID NOT NULL REFERENCES gallery_photos(id) ON DELETE RESTRICT,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    reaction_type VARCHAR(20) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_photo_reactions_type CHECK (reaction_type IN ('like', 'love', 'smile', 'heart')),
    CONSTRAINT uq_photo_reactions_photo_user UNIQUE (photo_id, user_id)
);

COMMENT ON TABLE photo_reactions IS 'Reacciones registradas por el adulto mayor u otros miembros sobre las fotos de la galería.';
COMMENT ON COLUMN photo_reactions.id IS 'Identificador único de la reacción.';
COMMENT ON COLUMN photo_reactions.photo_id IS 'Fotografía de la galería reaccionada.';
COMMENT ON COLUMN photo_reactions.user_id IS 'Usuario que emite la reacción (usualmente el adulto mayor).';
COMMENT ON COLUMN photo_reactions.reaction_type IS 'Tipo de reacción emotiva: like, love, smile, heart.';
COMMENT ON COLUMN photo_reactions.created_at IS 'Fecha y hora de registro de la reacción.';

CREATE INDEX ix_photo_reactions_photo 
ON photo_reactions(photo_id);
CREATE TABLE gallery_photos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
    published_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    file_id UUID NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
    caption TEXT,
    display_order INT DEFAULT 0 NOT NULL,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

COMMENT ON TABLE gallery_photos IS 'Fotografías familiares publicadas para reproducir en el carrusel del adulto mayor.';
COMMENT ON COLUMN gallery_photos.id IS 'Identificador único de la foto de galería.';
COMMENT ON COLUMN gallery_photos.patient_id IS 'Paciente destinatario de la foto.';
COMMENT ON COLUMN gallery_photos.published_by_user_id IS 'Usuario que subió la foto.';
COMMENT ON COLUMN gallery_photos.file_id IS 'Referencia al archivo en la tabla files.';
COMMENT ON COLUMN gallery_photos.caption IS 'Descripción o pie de foto opcional.';
COMMENT ON COLUMN gallery_photos.display_order IS 'Orden relativo de visualización en la pantalla completa.';
COMMENT ON COLUMN gallery_photos.deleted_at IS 'Fecha y hora de eliminación lógica (soft delete).';
COMMENT ON COLUMN gallery_photos.created_at IS 'Fecha y hora de publicación.';
COMMENT ON COLUMN gallery_photos.updated_at IS 'Fecha y hora de actualización.';

CREATE INDEX ix_gallery_photos_patient_order 
ON gallery_photos(patient_id, display_order ASC) WHERE deleted_at IS NULL;

CREATE TRIGGER tg_gallery_photos_updated_at
BEFORE UPDATE ON gallery_photos
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
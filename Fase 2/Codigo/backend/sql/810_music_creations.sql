CREATE TABLE music_creations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    title VARCHAR(150) NOT NULL,
    file_id UUID NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
    duration_seconds INT NOT NULL,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_music_creations_duration CHECK (duration_seconds > 0)
);

COMMENT ON TABLE music_creations IS 'Creaciones musicales grabadas o compuestas por el adulto mayor mediante la app.';
COMMENT ON COLUMN music_creations.id IS 'Identificador único de la creación musical.';
COMMENT ON COLUMN music_creations.patient_id IS 'Paciente creador de la pieza musical.';
COMMENT ON COLUMN music_creations.created_by_user_id IS 'Usuario creador (adulto mayor).';
COMMENT ON COLUMN music_creations.title IS 'Título otorgado a la creación musical.';
COMMENT ON COLUMN music_creations.file_id IS 'Referencia al archivo de audio almacenado en files.';
COMMENT ON COLUMN music_creations.duration_seconds IS 'Duración de la pista grabada en segundos.';
COMMENT ON COLUMN music_creations.deleted_at IS 'Fecha y hora de eliminación lógica.';
COMMENT ON COLUMN music_creations.created_at IS 'Fecha y hora de creación.';
COMMENT ON COLUMN music_creations.updated_at IS 'Fecha y hora de actualización.';

CREATE INDEX ix_music_creations_patient 
ON music_creations(patient_id) WHERE deleted_at IS NULL;

CREATE TRIGGER tg_music_creations_updated_at
BEFORE UPDATE ON music_creations
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
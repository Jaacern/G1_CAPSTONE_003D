CREATE TABLE content_playbacks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    content_item_id UUID NOT NULL REFERENCES content_items(id) ON DELETE RESTRICT,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    playback_seconds INT DEFAULT 0 NOT NULL,
    completed BOOLEAN DEFAULT false NOT NULL,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT chk_content_playbacks_time CHECK (finished_at IS NULL OR finished_at >= started_at),
    CONSTRAINT chk_content_playbacks_seconds CHECK (playback_seconds >= 0)
);

COMMENT ON TABLE content_playbacks IS 'Historial y métricas de consumo de contenido multimedia por parte del paciente.';
COMMENT ON COLUMN content_playbacks.id IS 'Identificador único de la sesión de reproducción.';
COMMENT ON COLUMN content_playbacks.content_item_id IS 'Contenido multimedia reproducido.';
COMMENT ON COLUMN content_playbacks.patient_id IS 'Paciente que consumió el contenido.';
COMMENT ON COLUMN content_playbacks.user_id IS 'Usuario ejecutor (adulto mayor con rol elder).';
COMMENT ON COLUMN content_playbacks.playback_seconds IS 'Tiempo total reproducido en segundos.';
COMMENT ON COLUMN content_playbacks.completed IS 'Indica si se completó la lectura/reproducción total.';
COMMENT ON COLUMN content_playbacks.started_at IS 'Fecha y hora de inicio de la reproducción.';
COMMENT ON COLUMN content_playbacks.finished_at IS 'Fecha y hora de finalización.';

CREATE INDEX ix_content_playbacks_patient_started 
ON content_playbacks(patient_id, started_at DESC);
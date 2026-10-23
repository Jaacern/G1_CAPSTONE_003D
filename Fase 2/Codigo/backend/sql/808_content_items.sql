CREATE TABLE content_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(150) NOT NULL,
    category VARCHAR(30) NOT NULL,
    media_type VARCHAR(20) NOT NULL,
    file_id UUID REFERENCES files(id) ON DELETE RESTRICT,
    external_url TEXT,
    duration_seconds INT,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_content_items_category CHECK (category IN ('music', 'radio', 'audiobook', 'game', 'exercise')),
    CONSTRAINT chk_content_items_media_type CHECK (media_type IN ('audio', 'video', 'interactive')),
    CONSTRAINT chk_content_items_source CHECK (
        (file_id IS NOT NULL AND external_url IS NULL) OR
        (file_id IS NULL AND external_url IS NOT NULL)
    ),
    CONSTRAINT chk_content_items_duration CHECK (duration_seconds IS NULL OR duration_seconds > 0)
);
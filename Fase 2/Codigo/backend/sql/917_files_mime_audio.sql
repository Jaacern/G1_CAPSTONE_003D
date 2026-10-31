-- AgeCare — Ajuste de compatibilidad
-- 917_files_mime_audio.sql — La BD acepta los formatos de audio que el front genera

ALTER TABLE files DROP CONSTRAINT IF EXISTS ck_files_mime_type;

ALTER TABLE files ADD CONSTRAINT ck_files_mime_type CHECK (
    mime_type IN (
        -- imagenes
        'image/jpeg', 'image/png', 'image/webp', 'image/heic',
        -- documentos
        'application/pdf',
        -- audio
        'audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/wav', 'audio/ogg'
    )
);

COMMENT ON COLUMN files.mime_type IS
    'Tipo de contenido, validado contra una lista cerrada (RF-39). Incluye los formatos de audio que genera la aplicacion al grabar notas de voz: aac en Android y wav en grabaciones sin comprimir.';

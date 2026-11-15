-- ============================================================================
-- BLOQUE 5 · Bitacora y archivos
-- 510_files.sql — Archivos subidos al expediente
-- Requisitos: RF-39 (subida por enlace temporal validando tipo y tamano),
--             RF-42 (descarga por enlace temporal corto), RNF-13 (enlaces <= 15 min)
-- ----------------------------------------------------------------------------
-- Separacion deliberada entre el ARCHIVO y el DOCUMENTO (515_medical_documents):
-- un archivo es el binario guardado en el almacenamiento; un documento es el
-- significado clinico que se le da. La misma foto puede ser el adjunto de una
-- observacion de la bitacora o un documento medico del expediente. Si se
-- mezclaran en una sola tabla, el tipo de dato y su uso quedarian atados.
--
-- La BD nunca guarda el binario. Guarda storage_key, que es la ruta opaca en
-- el almacenamiento (Azure Blob), y los metadatos para validar y auditar.
-- ============================================================================

CREATE TABLE files (
    id                uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id        uuid         NOT NULL,
    uploaded_by       uuid         NOT NULL,
    storage_key       varchar(300) NOT NULL,
    original_name     varchar(255) NOT NULL,
    mime_type         varchar(100) NOT NULL,
    size_bytes        bigint       NOT NULL,
    checksum_sha256   char(64),
    status            varchar(12)  NOT NULL DEFAULT 'pending',
    upload_expires_at timestamptz  NOT NULL,
    stored_at         timestamptz,
    purged_at         timestamptz,
    created_at        timestamptz  NOT NULL DEFAULT now(),
    updated_at        timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_files_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_files_uploaded_by
        FOREIGN KEY (uploaded_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT uq_files_storage_key UNIQUE (storage_key),

    -- RF-39: el tipo se valida en el motor, no solo en la aplicacion.
    CONSTRAINT ck_files_mime_type CHECK (
        mime_type IN ('image/jpeg','image/png','image/webp','image/heic',
                      'application/pdf','audio/mpeg','audio/mp4','audio/ogg')
    ),
    -- RF-39: techo duro de 25 MB. El limite real por plan vive en
    -- plan_limits (max_storage_mb) y el operativo en system_parameters;
    -- este CHECK es la ultima linea de defensa.
    CONSTRAINT ck_files_size_bytes CHECK (size_bytes BETWEEN 1 AND 26214400),

    CONSTRAINT ck_files_status CHECK (status IN ('pending','stored','purged')),
    -- Coherencia de estado: un archivo almacenado tiene fecha de almacenamiento
    -- y un archivo depurado tiene fecha de depuracion. No hay estados a medias.
    CONSTRAINT ck_files_status_dates CHECK (
        (status = 'pending' AND stored_at IS NULL  AND purged_at IS NULL)
     OR (status = 'stored'  AND stored_at IS NOT NULL AND purged_at IS NULL)
     OR (status = 'purged'  AND stored_at IS NOT NULL AND purged_at IS NOT NULL)
    )
);

-- Listado de archivos de un paciente, del mas nuevo al mas viejo.
CREATE INDEX ix_files_patient_created
    ON files (patient_id, created_at DESC);

-- Subidas que nunca se completaron: las barre el proceso de limpieza.
CREATE INDEX ix_files_pending_expired
    ON files (upload_expires_at)
    WHERE status = 'pending';

COMMENT ON TABLE  files IS 'Archivos binarios del expediente. La BD guarda metadatos y la ruta opaca del almacenamiento, nunca el contenido. RF-39, RF-42.';
COMMENT ON COLUMN files.id IS 'Identificador del archivo.';
COMMENT ON COLUMN files.patient_id IS 'Paciente a cuyo expediente pertenece el archivo.';
COMMENT ON COLUMN files.uploaded_by IS 'Usuario que subio el archivo.';
COMMENT ON COLUMN files.storage_key IS 'Ruta opaca en el almacenamiento externo. No es adivinable desde la aplicacion.';
COMMENT ON COLUMN files.original_name IS 'Nombre con que el usuario subio el archivo. Solo para mostrarlo.';
COMMENT ON COLUMN files.mime_type IS 'Tipo de contenido validado contra la lista permitida (RF-39).';
COMMENT ON COLUMN files.size_bytes IS 'Tamano en bytes. Techo duro de 25 MB (RF-39).';
COMMENT ON COLUMN files.checksum_sha256 IS 'Huella SHA-256 del contenido. Permite detectar duplicados y corrupcion.';
COMMENT ON COLUMN files.status IS 'Ciclo de vida del archivo: pending (enlace emitido), stored (subido), purged (binario eliminado).';
COMMENT ON COLUMN files.upload_expires_at IS 'Vencimiento del enlace de subida. RNF-13 exige 15 minutos o menos.';
COMMENT ON COLUMN files.stored_at IS 'Momento en que el almacenamiento confirmo la subida.';
COMMENT ON COLUMN files.purged_at IS 'Momento en que se elimino el binario. La fila se conserva como registro (RF-43).';
COMMENT ON COLUMN files.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN files.updated_at IS 'Fecha de la ultima modificacion del registro.';

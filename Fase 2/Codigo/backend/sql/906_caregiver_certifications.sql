-- AgeCare — Bloque 9: Marketplace
-- Tabla 6 de 9: caregiver_certifications


CREATE TABLE caregiver_certifications (
    id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id   uuid         NOT NULL,
    name         varchar(120) NOT NULL,
    issuer       varchar(120) NOT NULL,
    issued_at    date,
    expires_at   date,
    storage_key  varchar(300),
    mime_type    varchar(100),
    size_bytes   bigint,
    verified_at  timestamptz,
    verified_by  uuid,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    deleted_at   timestamptz,

    CONSTRAINT fk_caregiver_certifications_profile
        FOREIGN KEY (profile_id) REFERENCES caregiver_profiles(id) ON DELETE RESTRICT,
    CONSTRAINT fk_caregiver_certifications_verified_by
        FOREIGN KEY (verified_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT uq_caregiver_certifications_storage UNIQUE (storage_key),

    CONSTRAINT ck_caregiver_certifications_name CHECK (btrim(name) <> ''),
    CONSTRAINT ck_caregiver_certifications_issuer CHECK (btrim(issuer) <> ''),
    CONSTRAINT ck_caregiver_certifications_vigencia
        CHECK (expires_at IS NULL OR issued_at IS NULL OR expires_at > issued_at),
    -- El archivo de respaldo va completo o no va.
    CONSTRAINT ck_caregiver_certifications_archivo CHECK (
        (storage_key IS NULL AND mime_type IS NULL AND size_bytes IS NULL)
     OR (storage_key IS NOT NULL AND mime_type IS NOT NULL AND size_bytes IS NOT NULL)
    ),
    CONSTRAINT ck_caregiver_certifications_mime CHECK (
        mime_type IS NULL OR mime_type IN ('image/jpeg','image/png','application/pdf')
    ),
    CONSTRAINT ck_caregiver_certifications_size
        CHECK (size_bytes IS NULL OR size_bytes BETWEEN 1 AND 26214400),
    -- La verificación registra siempre quién la hizo.
    CONSTRAINT ck_caregiver_certifications_verificacion
        CHECK ((verified_at IS NULL) = (verified_by IS NULL)),
    -- No se puede dar por verificado un certificado sin documento de respaldo.
    CONSTRAINT ck_caregiver_certifications_verificado_con_archivo
        CHECK (verified_at IS NULL OR storage_key IS NOT NULL)
);

-- RF-76: las certificaciones vigentes de un perfil, que es lo que se muestra.
CREATE INDEX ix_caregiver_certifications_perfil
    ON caregiver_certifications (profile_id, expires_at DESC NULLS FIRST)
    WHERE deleted_at IS NULL;

-- Cola de certificados pendientes de verificar.
CREATE INDEX ix_caregiver_certifications_por_verificar
    ON caregiver_certifications (created_at)
    WHERE verified_at IS NULL AND deleted_at IS NULL;

CREATE TRIGGER tg_caregiver_certifications_updated_at
    BEFORE UPDATE ON caregiver_certifications
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  caregiver_certifications IS
    'Certificaciones declaradas por cada cuidadora, con vigencia y verificación. Normalización 1FN. El respaldo no apunta a files porque files exige un paciente y un certificado no pertenece a ninguno. RF-72, RF-76.';
COMMENT ON COLUMN caregiver_certifications.id IS
    'Identificador de la certificación.';
COMMENT ON COLUMN caregiver_certifications.profile_id IS
    'Perfil que declara la certificación.';
COMMENT ON COLUMN caregiver_certifications.name IS
    'Nombre del curso o título obtenido.';
COMMENT ON COLUMN caregiver_certifications.issuer IS
    'Institución que lo emitió.';
COMMENT ON COLUMN caregiver_certifications.issued_at IS
    'Fecha de emisión.';
COMMENT ON COLUMN caregiver_certifications.expires_at IS
    'Fecha de vencimiento. Nula si el certificado no vence.';
COMMENT ON COLUMN caregiver_certifications.storage_key IS
    'Ruta opaca del documento de respaldo en el almacenamiento.';
COMMENT ON COLUMN caregiver_certifications.mime_type IS
    'Tipo de contenido del respaldo, validado contra la lista permitida.';
COMMENT ON COLUMN caregiver_certifications.size_bytes IS
    'Tamaño del respaldo en bytes. Techo de 25 MB, igual que en files.';
COMMENT ON COLUMN caregiver_certifications.verified_at IS
    'Momento en que alguien revisó el documento y dio por válida la certificación.';
COMMENT ON COLUMN caregiver_certifications.verified_by IS
    'Quién la verificó.';
COMMENT ON COLUMN caregiver_certifications.created_at IS
    'Fecha de creación del registro.';
COMMENT ON COLUMN caregiver_certifications.updated_at IS
    'Fecha de la última modificación del registro.';
COMMENT ON COLUMN caregiver_certifications.deleted_at IS
    'Baja lógica. La fila se conserva.';

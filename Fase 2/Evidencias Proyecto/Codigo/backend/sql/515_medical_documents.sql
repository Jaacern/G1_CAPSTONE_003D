-- ============================================================================
-- BLOQUE 5 · Bitacora y archivos
-- 515_medical_documents.sql — Documentos medicos del expediente
-- Requisitos: RF-40 (asociar archivo al expediente como documento medico),
--             RF-41 (consultar documentos con filtro por categoria),
--             RF-43 (eliminar documento conservando registro, con depuracion
--                    posterior)
-- ----------------------------------------------------------------------------
-- RF-43 es exactamente la politica de conservacion del proyecto, pero en dos
-- niveles:
--   · El DOCUMENTO se da de baja con deleted_at. La fila queda: se sabe que
--     existio, quien lo subio, quien lo borro y cuando.
--   · El ARCHIVO (files) se depura aparte con files.purged_at. El binario
--     desaparece del almacenamiento, el registro no.
-- Esa separacion es la que permite cumplir una solicitud de eliminacion de
-- datos personales sin perder la trazabilidad del expediente.
--
-- document_date existe porque la fecha del examen y la fecha en que alguien lo
-- subio al sistema casi nunca son la misma, y el expediente se ordena por la
-- primera.
-- ============================================================================

CREATE TABLE medical_documents (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    uuid         NOT NULL,
    file_id       uuid         NOT NULL,
    category      varchar(20)  NOT NULL,
    title         varchar(160) NOT NULL,
    description   varchar(500),
    document_date date,
    issued_by     varchar(120),
    added_by      uuid         NOT NULL,
    deleted_at    timestamptz,
    deleted_by    uuid,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_medical_documents_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_medical_documents_file
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE RESTRICT,
    CONSTRAINT fk_medical_documents_added_by
        FOREIGN KEY (added_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_medical_documents_deleted_by
        FOREIGN KEY (deleted_by) REFERENCES users(id) ON DELETE RESTRICT,

    -- Un archivo se presenta como un solo documento medico.
    CONSTRAINT uq_medical_documents_file UNIQUE (file_id),

    CONSTRAINT ck_medical_documents_category CHECK (
        category IN ('prescription','lab_result','imaging','report',
                     'discharge','consent','insurance','other')
    ),
    CONSTRAINT ck_medical_documents_title CHECK (btrim(title) <> ''),
    -- RF-43: la baja registra siempre quien la hizo.
    CONSTRAINT ck_medical_documents_delete CHECK (
        (deleted_at IS NULL) = (deleted_by IS NULL)
    )
);

-- RF-41: listado del expediente con filtro por categoria.
CREATE INDEX ix_medical_documents_patient_categoria
    ON medical_documents (patient_id, category, document_date DESC)
    WHERE deleted_at IS NULL;

-- Documentos dados de baja cuyo archivo todavia no se ha depurado (RF-43).
CREATE INDEX ix_medical_documents_por_depurar
    ON medical_documents (deleted_at)
    WHERE deleted_at IS NOT NULL;

COMMENT ON TABLE  medical_documents IS 'Documentos medicos del expediente. Da significado clinico a un archivo de la tabla files. La baja conserva la fila y la depuracion del binario es posterior. RF-40, RF-41, RF-43.';
COMMENT ON COLUMN medical_documents.id IS 'Identificador del documento.';
COMMENT ON COLUMN medical_documents.patient_id IS 'Paciente cuyo expediente contiene el documento.';
COMMENT ON COLUMN medical_documents.file_id IS 'Archivo que respalda el documento.';
COMMENT ON COLUMN medical_documents.category IS 'Categoria del documento. Lista cerrada para que RF-41 pueda filtrar.';
COMMENT ON COLUMN medical_documents.title IS 'Titulo con que se muestra el documento. No puede quedar vacio.';
COMMENT ON COLUMN medical_documents.description IS 'Detalle opcional del contenido.';
COMMENT ON COLUMN medical_documents.document_date IS 'Fecha del documento en si, distinta de la fecha de subida.';
COMMENT ON COLUMN medical_documents.issued_by IS 'Profesional o institucion que emitio el documento, como texto.';
COMMENT ON COLUMN medical_documents.added_by IS 'Usuario que incorporo el documento al expediente.';
COMMENT ON COLUMN medical_documents.deleted_at IS 'Momento de la baja logica. La fila se conserva (RF-43).';
COMMENT ON COLUMN medical_documents.deleted_by IS 'Usuario que dio de baja el documento.';
COMMENT ON COLUMN medical_documents.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN medical_documents.updated_at IS 'Fecha de la ultima modificacion del registro.';

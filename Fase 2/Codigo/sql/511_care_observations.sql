-- ============================================================================
-- BLOQUE 5 · Bitacora y archivos
-- 511_care_observations.sql — Observaciones de la cuidadora
-- Requisitos: RF-34 (registrar observacion por categoria con foto opcional),
--             RF-35 (consultar la bitacora con filtros)
-- ----------------------------------------------------------------------------
-- Dos momentos distintos, igual que en scheduled_doses:
--   observed_at = cuando ocurrio lo observado (hecho clinico)
--   created_at  = cuando se registro en el sistema (acto administrativo)
-- Si se guardara uno solo, una observacion escrita a las 23:00 sobre algo que
-- paso a las 08:00 quedaria mal fechada en el expediente.
-- ============================================================================

CREATE TABLE care_observations (
    id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    uuid          NOT NULL,
    author_id     uuid          NOT NULL,
    category      varchar(20)   NOT NULL,
    note          varchar(1000) NOT NULL,
    photo_file_id uuid,
    observed_at   timestamptz   NOT NULL,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    updated_at    timestamptz   NOT NULL DEFAULT now(),
    deleted_at    timestamptz,

    CONSTRAINT fk_care_observations_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_care_observations_author
        FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_care_observations_photo
        FOREIGN KEY (photo_file_id) REFERENCES files(id) ON DELETE RESTRICT,

    -- RF-34: la categoria es cerrada porque RF-35 filtra por ella. Texto libre
    -- haria imposible el filtro y el analisis posterior.
    CONSTRAINT ck_care_observations_category CHECK (
        category IN ('mood','food','hygiene','sleep','mobility','pain',
                     'medication','visit','other')
    ),
    CONSTRAINT ck_care_observations_note CHECK (btrim(note) <> '')
);

-- RF-35: la bitacora se lee por paciente y en orden cronologico inverso.
CREATE INDEX ix_care_observations_patient_observed
    ON care_observations (patient_id, observed_at DESC)
    WHERE deleted_at IS NULL;

-- RF-35: filtro por categoria dentro de un paciente.
CREATE INDEX ix_care_observations_patient_category
    ON care_observations (patient_id, category, observed_at DESC)
    WHERE deleted_at IS NULL;

COMMENT ON TABLE  care_observations IS 'Observaciones que registra la cuidadora sobre el dia del paciente. Nucleo de la bitacora del expediente. RF-34, RF-35.';
COMMENT ON COLUMN care_observations.id IS 'Identificador de la observacion.';
COMMENT ON COLUMN care_observations.patient_id IS 'Paciente observado.';
COMMENT ON COLUMN care_observations.author_id IS 'Usuario que escribio la observacion.';
COMMENT ON COLUMN care_observations.category IS 'Categoria de la observacion. Lista cerrada para que RF-35 pueda filtrar.';
COMMENT ON COLUMN care_observations.note IS 'Texto de la observacion. No puede quedar vacio.';
COMMENT ON COLUMN care_observations.photo_file_id IS 'Foto adjunta opcional (RF-34).';
COMMENT ON COLUMN care_observations.observed_at IS 'Momento en que ocurrio lo observado. Lo informa quien registra.';
COMMENT ON COLUMN care_observations.created_at IS 'Momento en que la observacion entro al sistema.';
COMMENT ON COLUMN care_observations.updated_at IS 'Fecha de la ultima correccion del texto.';
COMMENT ON COLUMN care_observations.deleted_at IS 'Marca de baja. La fila se conserva, deja de mostrarse.';

-- ============================================================================
-- BLOQUE 5 · Bitacora y archivos
-- 513_shift_notes.sql — Notas de relevo entre turnos
-- Requisitos: RF-37 (notas de relevo entre turnos)
-- ----------------------------------------------------------------------------
-- El relevo es el punto donde se pierde informacion en el cuidado real: la
-- cuidadora de la manana sabe algo que la de la tarde no. La nota de relevo es
-- un documento por turno, no un mensaje de chat, y por eso tiene fecha de
-- turno, autor, destinatario y acuse de lectura.
--
-- UNIQUE (patient_id, shift_date, shift): un turno deja una sola nota. Si se
-- permitieran varias, el turno siguiente no sabria cual es la vigente.
-- ============================================================================

CREATE TABLE shift_notes (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid          NOT NULL,
    author_id       uuid          NOT NULL,
    shift_date      date          NOT NULL,
    shift           varchar(10)   NOT NULL,
    note            varchar(2000) NOT NULL,
    handover_to     uuid,
    acknowledged_by uuid,
    acknowledged_at timestamptz,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    deleted_at      timestamptz,

    CONSTRAINT fk_shift_notes_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_shift_notes_author
        FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_shift_notes_handover_to
        FOREIGN KEY (handover_to) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_shift_notes_acknowledged_by
        FOREIGN KEY (acknowledged_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT uq_shift_notes_turno UNIQUE (patient_id, shift_date, shift),

    CONSTRAINT ck_shift_notes_shift CHECK (
        shift IN ('morning','afternoon','night')
    ),
    CONSTRAINT ck_shift_notes_note CHECK (btrim(note) <> ''),
    -- El acuse es un solo hecho: o esta completo o no existe.
    CONSTRAINT ck_shift_notes_ack CHECK (
        (acknowledged_at IS NULL) = (acknowledged_by IS NULL)
    )
);

-- RF-70 (vista del dia) necesita la ultima nota de relevo del paciente.
CREATE INDEX ix_shift_notes_patient_fecha
    ON shift_notes (patient_id, shift_date DESC, shift)
    WHERE deleted_at IS NULL;

-- Notas que el turno siguiente todavia no leyo.
CREATE INDEX ix_shift_notes_sin_acuse
    ON shift_notes (handover_to, shift_date DESC)
    WHERE acknowledged_at IS NULL AND deleted_at IS NULL;

COMMENT ON TABLE  shift_notes IS 'Notas de relevo que deja cada turno al siguiente. Una por paciente, fecha y turno. RF-37.';
COMMENT ON COLUMN shift_notes.id IS 'Identificador de la nota de relevo.';
COMMENT ON COLUMN shift_notes.patient_id IS 'Paciente al que se refiere el relevo.';
COMMENT ON COLUMN shift_notes.author_id IS 'Usuario que entrega el turno y escribe la nota.';
COMMENT ON COLUMN shift_notes.shift_date IS 'Fecha del turno que se esta entregando.';
COMMENT ON COLUMN shift_notes.shift IS 'Turno entregado: morning, afternoon o night.';
COMMENT ON COLUMN shift_notes.note IS 'Contenido del relevo. No puede quedar vacio.';
COMMENT ON COLUMN shift_notes.handover_to IS 'Usuario que recibe el turno, cuando se conoce de antemano.';
COMMENT ON COLUMN shift_notes.acknowledged_by IS 'Usuario que confirmo haber leido la nota.';
COMMENT ON COLUMN shift_notes.acknowledged_at IS 'Momento del acuse de lectura.';
COMMENT ON COLUMN shift_notes.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN shift_notes.updated_at IS 'Fecha de la ultima modificacion del registro.';
COMMENT ON COLUMN shift_notes.deleted_at IS 'Marca de baja. La fila se conserva, deja de mostrarse.';

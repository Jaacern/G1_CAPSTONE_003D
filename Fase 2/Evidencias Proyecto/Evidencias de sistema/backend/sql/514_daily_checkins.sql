-- ============================================================================
-- BLOQUE 5 · Bitacora y archivos
-- 514_daily_checkins.sql — Check-in diario del adulto mayor
-- Requisitos: RF-38 (check-in diario del adulto mayor, uno por dia)
-- ----------------------------------------------------------------------------
-- Esta tabla NO tiene author_id, y eso es intencional. El adulto mayor no es
-- un usuario del sistema: no introduce credenciales, su dispositivo se vincula
-- por codigo (RF-68, bloque 6). El autor del check-in es el paciente mismo,
-- asi que patient_id ya lo identifica. Agregar un author_id obligaria a crear
-- cuentas falsas para adultos mayores.
--
-- "Uno por dia" de RF-38 lo impone UNIQUE (patient_id, checkin_date), no la
-- aplicacion. Dos check-ins del mismo dia son imposibles a nivel de motor.
--
-- voice_file_id existe porque RNF-20 exige que el adulto mayor pueda hacer
-- las acciones principales sin teclado. El check-in se puede responder hablando.
-- ============================================================================

CREATE TABLE daily_checkins (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    uuid         NOT NULL,
    checkin_date  date         NOT NULL,
    mood          varchar(10)  NOT NULL,
    pain_level    smallint,
    slept_well    boolean,
    ate_well      boolean,
    note          varchar(500),
    voice_file_id uuid,
    source        varchar(10)  NOT NULL DEFAULT 'elder',
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_daily_checkins_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_daily_checkins_voice
        FOREIGN KEY (voice_file_id) REFERENCES files(id) ON DELETE RESTRICT,

    -- RF-38: uno por dia. Lo garantiza el motor.
    CONSTRAINT uq_daily_checkins_dia UNIQUE (patient_id, checkin_date),

    CONSTRAINT ck_daily_checkins_mood CHECK (
        mood IN ('good','regular','bad')
    ),
    -- Escala de dolor de 0 a 10, la misma que usa el personal de salud.
    CONSTRAINT ck_daily_checkins_pain CHECK (
        pain_level IS NULL OR pain_level BETWEEN 0 AND 10
    ),
    CONSTRAINT ck_daily_checkins_source CHECK (
        source IN ('elder','caregiver')
    )
);

-- Serie de check-ins de un paciente, para graficar la tendencia.
CREATE INDEX ix_daily_checkins_patient_fecha
    ON daily_checkins (patient_id, checkin_date DESC);

-- Dias que el paciente reporto mal: alimentan el semaforo de bienestar (RF-22).
CREATE INDEX ix_daily_checkins_malos
    ON daily_checkins (patient_id, checkin_date DESC)
    WHERE mood = 'bad';

COMMENT ON TABLE  daily_checkins IS 'Check-in diario que responde el adulto mayor desde su dispositivo. Uno por paciente y dia. Sin autor porque el adulto mayor no es usuario del sistema. RF-38.';
COMMENT ON COLUMN daily_checkins.id IS 'Identificador del check-in.';
COMMENT ON COLUMN daily_checkins.patient_id IS 'Adulto mayor que responde.';
COMMENT ON COLUMN daily_checkins.checkin_date IS 'Dia al que corresponde el check-in.';
COMMENT ON COLUMN daily_checkins.mood IS 'Como dice sentirse: good, regular o bad.';
COMMENT ON COLUMN daily_checkins.pain_level IS 'Dolor declarado en escala de 0 a 10. Nulo si no respondio.';
COMMENT ON COLUMN daily_checkins.slept_well IS 'Si durmio bien. Nulo si no respondio.';
COMMENT ON COLUMN daily_checkins.ate_well IS 'Si comio bien. Nulo si no respondio.';
COMMENT ON COLUMN daily_checkins.note IS 'Comentario libre del adulto mayor.';
COMMENT ON COLUMN daily_checkins.voice_file_id IS 'Nota de voz con la respuesta, para operar sin teclado (RNF-20).';
COMMENT ON COLUMN daily_checkins.source IS 'Quien lo ingreso: elder (el propio adulto mayor) o caregiver (lo tomo la cuidadora).';
COMMENT ON COLUMN daily_checkins.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN daily_checkins.updated_at IS 'Fecha de la ultima correccion del registro.';

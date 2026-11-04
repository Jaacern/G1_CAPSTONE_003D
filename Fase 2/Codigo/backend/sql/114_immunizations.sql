-- AgeCare — Bloque 1: Identidad y acceso
-- 114_immunizations.sql — Inmunizaciones / vacunas del paciente (Fase 6)
--
-- POR QUÉ
--   La ficha del adulto mayor debe registrar las vacunas: las preventivas del
--   programa (influenza anual, neumocócica, herpes zóster, dT, COVID) y las de
--   post-exposición gatilladas por un hecho (antirrábica tras mordedura,
--   antitetánica tras herida). Las preventivas tienen "próxima dosis"; las de
--   post-exposición son un evento fechado. Fuente: Programa Nacional de
--   Inmunizaciones (PNI) del MINSAL y calendario del adulto mayor
--   (ver docs/MODELO_CLINICO_CASO_REAL.md).
--
-- Correcciones 2FN / 3FN aplicadas (mismo criterio que vital_types / vital_readings):
--   · Las propiedades inherentes de cada vacuna (si es recurrente, su intervalo
--     recomendado, su naturaleza y grupo objetivo) viven SOLO en el catálogo
--     vaccine_catalog, no se repiten en cada dosis registrada (evita dependencia
--     transitiva → 3FN).
--   · patient_immunizations referencia el catálogo por FK a vaccine_catalog.code,
--     reemplazando cualquier CHECK de lista duplicada (igual que vital_readings
--     apunta a vital_types.code). El catálogo es la fuente única de verdad.
--   · No se guarda patient_id donde dependa de otra FK: cada dosis depende solo
--     de su propia PK (id); patient_id es atributo directo de la dosis (quién la
--     recibió), no una dependencia parcial.

-- ─────────────────────────────────────────────────────────────────
-- vaccine_catalog — catálogo de vacunas (fuente única de verdad)
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE vaccine_catalog (
    code                varchar(30)  PRIMARY KEY,
    label               varchar(100) NOT NULL,
    -- Naturaleza por defecto: preventiva (programa) o post_exposicion (evento).
    kind_default        varchar(20)  NOT NULL DEFAULT 'preventiva',
    -- true si se repite en el tiempo (influenza anual, refuerzos). Define si
    -- tiene sentido calcular next_due_on con el intervalo recomendado.
    is_recurrent        boolean      NOT NULL DEFAULT false,
    -- Intervalo recomendado entre dosis, en meses. NULL = dosis única / no aplica.
    interval_months     int,
    -- Grupo objetivo (texto informativo del PNI; para mostrar, no para lógica).
    target_group        varchar(80),

    CONSTRAINT ck_vaccine_catalog_code_min
        CHECK (char_length(code) >= 2),
    CONSTRAINT ck_vaccine_catalog_kind
        CHECK (kind_default IN ('preventiva', 'post_exposicion')),
    CONSTRAINT ck_vaccine_catalog_interval
        CHECK (interval_months IS NULL OR interval_months > 0)
);

COMMENT ON TABLE  vaccine_catalog IS
    'Catálogo de vacunas (fuente única de verdad, igual que vital_types). Las propiedades inherentes de cada vacuna (naturaleza, si es recurrente, intervalo recomendado, grupo objetivo) viven aquí, no se repiten por dosis (3FN). Fuente: Programa Nacional de Inmunizaciones (PNI) MINSAL.';
COMMENT ON COLUMN vaccine_catalog.kind_default IS
    'Naturaleza por defecto: preventiva (programa, con próxima dosis) | post_exposicion (evento gatillado, p. ej. antirrábica tras mordedura).';
COMMENT ON COLUMN vaccine_catalog.is_recurrent IS
    'true si se repite en el tiempo (influenza anual, refuerzos). Habilita el cálculo de next_due_on con interval_months.';
COMMENT ON COLUMN vaccine_catalog.interval_months IS
    'Intervalo recomendado entre dosis, en meses. NULL = dosis única o no aplica.';
COMMENT ON COLUMN vaccine_catalog.target_group IS
    'Grupo objetivo según el PNI (texto informativo para mostrar, no para lógica).';

INSERT INTO vaccine_catalog
    (code, label, kind_default, is_recurrent, interval_months, target_group) VALUES
    -- Preventivas del programa del adulto mayor
    ('influenza',    'Influenza (anual)',             'preventiva', true,  12,  'Personas de 65 años o más (campaña anual)'),
    ('neumococica_23','Neumocócica polisacárida 23v', 'preventiva', false, NULL,'Adulto mayor (dosis única del programa)'),
    ('neumococica_13','Neumocócica conjugada 13v',    'preventiva', false, NULL,'Adulto mayor / grupos de riesgo'),
    ('herpes_zoster','Herpes zóster',                 'preventiva', true,  2,   'Adulto mayor (2 dosis separadas)'),
    ('dtpa',         'dTpa (difteria-tétanos-tos convulsiva)','preventiva', true, 120, 'Refuerzo cada 10 años'),
    ('dt',           'dT (difteria-tétanos)',         'preventiva', true,  120, 'Refuerzo cada 10 años'),
    ('covid_19',     'COVID-19 (refuerzo)',           'preventiva', true,  12,  'Adulto mayor / grupos de riesgo'),
    -- Post-exposición (evento gatillado por un hecho)
    ('antirrabica',  'Antirrábica',                   'post_exposicion', false, NULL, 'Tras mordedura o contacto con animal sospechoso'),
    ('antitetanica', 'Antitetánica (post-herida)',    'post_exposicion', false, NULL, 'Tras herida con riesgo de tétanos');


-- ─────────────────────────────────────────────────────────────────
-- patient_immunizations — dosis aplicadas / programadas al paciente
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE patient_immunizations (
    id              uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid         NOT NULL,
    -- FK al catálogo: fuente única de verdad del dominio de vacunas (como
    -- vital_readings.type → vital_types.code). Reemplaza un CHECK de lista.
    vaccine         varchar(30)  NOT NULL,
    -- Naturaleza de ESTA dosis. Por defecto hereda la del catálogo, pero se
    -- guarda explícita por si un caso concreto difiere (flexibilidad clínica).
    kind            varchar(20)  NOT NULL DEFAULT 'preventiva',
    -- Cuándo se administró (hecho clínico). NULL = registrada como pendiente.
    administered_on date,
    -- Próxima dosis recomendada (solo preventivas recurrentes). La calcula la
    -- aplicación con interval_months; se persiste para ordenar recordatorios.
    next_due_on     date,
    dose_number     smallint,                -- n.º de dosis (1, 2, refuerzo...)
    -- Para post-exposición: descripción del evento que la gatilló.
    exposure_event  varchar(200),
    note            varchar(200),
    recorded_by     uuid,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    deleted_at      timestamptz,             -- baja lógica: conserva histórico

    CONSTRAINT fk_patient_immunizations_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_patient_immunizations_vaccine
        FOREIGN KEY (vaccine) REFERENCES vaccine_catalog(code) ON DELETE RESTRICT,
    CONSTRAINT fk_patient_immunizations_user
        FOREIGN KEY (recorded_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT ck_patient_immunizations_kind
        CHECK (kind IN ('preventiva', 'post_exposicion')),
    CONSTRAINT ck_patient_immunizations_dose
        CHECK (dose_number IS NULL OR dose_number > 0),
    -- Debe tener al menos una fecha: o se administró, o está pendiente (next_due).
    CONSTRAINT ck_patient_immunizations_alguna_fecha
        CHECK (administered_on IS NOT NULL OR next_due_on IS NOT NULL)
);

-- Consulta frecuente: carnet de vacunas del paciente, lo más reciente primero.
CREATE INDEX ix_patient_immunizations_patient
    ON patient_immunizations (patient_id, administered_on DESC)
    WHERE deleted_at IS NULL;

-- Recordatorios: próximas dosis vencidas o por vencer.
CREATE INDEX ix_patient_immunizations_due
    ON patient_immunizations (next_due_on)
    WHERE deleted_at IS NULL AND next_due_on IS NOT NULL;

CREATE TRIGGER tg_patient_immunizations_updated_at
    BEFORE UPDATE ON patient_immunizations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  patient_immunizations IS
    'Vacunas aplicadas o programadas al paciente (carnet de inmunizaciones). FK a vaccine_catalog (fuente única de verdad). Baja lógica para conservar el histórico. Las preventivas recurrentes calculan next_due_on; las de post-exposición registran el evento que las gatilló.';
COMMENT ON COLUMN patient_immunizations.vaccine IS
    'Vacuna. FK a vaccine_catalog.code (catálogo centralizado). Reemplaza un CHECK de lista duplicada.';
COMMENT ON COLUMN patient_immunizations.kind IS
    'Naturaleza de esta dosis: preventiva | post_exposicion. Por defecto hereda la del catálogo; explícita por si un caso difiere.';
COMMENT ON COLUMN patient_immunizations.administered_on IS
    'Fecha de administración (hecho clínico). NULL cuando la dosis está solo programada/pendiente.';
COMMENT ON COLUMN patient_immunizations.next_due_on IS
    'Próxima dosis recomendada (solo preventivas recurrentes). Calculada por la app con vaccine_catalog.interval_months; se persiste para ordenar recordatorios.';
COMMENT ON COLUMN patient_immunizations.exposure_event IS
    'Solo post-exposición: descripción del hecho que gatilló la vacuna (ej. "mordedura de perro callejero").';

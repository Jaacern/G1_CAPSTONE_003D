-- AgeCare — Bloque 1: Identidad y acceso
-- 111_condition_catalog.sql — Patologías con catálogo y agrupación por sistema (Fase 3)
--
-- POR QUÉ
--   La ficha real de un adulto mayor (EMPAM/CESFAM) lista los antecedentes
--   mórbidos AGRUPADOS POR SISTEMA: cardiovasculares (HTA, DM2, IAM...),
--   respiratorios (EPOC, asma...), síndromes geriátricos (caídas, deterioro
--   cognitivo, polifarmacia...), y otras. Hoy patient_conditions guarda texto
--   plano sin grupo. Agregamos:
--     · un CATÁLOGO semilla de patologías con su sistema (condition_catalog),
--     · una columna 'system' en patient_conditions para agrupar en la ficha.
--
--   El catálogo es semilla (los más comunes del caso real + habituales). El
--   médico igual puede escribir una condición libre; si no está en el catálogo,
--   queda con system='otras'.
--
--   Fuente del vocabulario y la agrupación: ficha EMPAM/CESFAM y guías MINSAL
--   (ver docs/MODELO_CLINICO_CASO_REAL.md, sección bibliografía).

-- Columna de sistema en las condiciones del paciente.
ALTER TABLE patient_conditions
    ADD COLUMN IF NOT EXISTS system varchar(20) NOT NULL DEFAULT 'otras';

ALTER TABLE patient_conditions DROP CONSTRAINT IF EXISTS ck_patient_conditions_system;
ALTER TABLE patient_conditions ADD CONSTRAINT ck_patient_conditions_system CHECK (
    system IN ('cardiovascular','respiratorio','geriatrico','metabolico',
               'osteomuscular','neuropsiquiatrico','sensorial','otras')
);

COMMENT ON COLUMN patient_conditions.system IS
    'Sistema/grupo clínico de la condición (cardiovascular, respiratorio, geriatrico, metabolico, osteomuscular, neuropsiquiatrico, sensorial, otras). Permite agrupar la ficha como el EMPAM. Default otras para texto libre.';


-- ─────────────────────────────────────────────────────────────────
-- condition_catalog — vocabulario semilla de patologías por sistema
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE condition_catalog (
    code    varchar(40)  PRIMARY KEY,   -- código estable (ej. hipertension)
    label   varchar(100) NOT NULL,      -- etiqueta legible (ej. Hipertensión arterial)
    system  varchar(20)  NOT NULL,

    CONSTRAINT ck_condition_catalog_system CHECK (
        system IN ('cardiovascular','respiratorio','geriatrico','metabolico',
                   'osteomuscular','neuropsiquiatrico','sensorial','otras')
    )
);

COMMENT ON TABLE condition_catalog IS
    'Catálogo semilla de patologías agrupadas por sistema, tomado de la ficha EMPAM/CESFAM. El médico puede elegir del catálogo (hereda el sistema) o escribir libre (queda en otras).';

INSERT INTO condition_catalog (code, label, system) VALUES
    -- Cardiovascular
    ('hipertension',              'Hipertensión arterial (HTA)',          'cardiovascular'),
    ('insuficiencia_cardiaca',    'Insuficiencia cardíaca',               'cardiovascular'),
    ('cardiopatia_dilatada',      'Cardiopatía dilatada',                 'cardiovascular'),
    ('iam',                       'Infarto agudo al miocardio (IAM)',     'cardiovascular'),
    ('ave',                       'Accidente vascular encefálico (AVE)',  'cardiovascular'),
    ('arritmia',                  'Arritmia',                             'cardiovascular'),
    ('marcapaso',                 'Portador de marcapaso',                'cardiovascular'),
    -- Metabólico / endocrino
    ('diabetes_tipo_2',           'Diabetes mellitus tipo 2 (DM2)',       'metabolico'),
    ('diabetes_insulino',         'Diabetes insulinodependiente',         'metabolico'),
    ('dislipidemia',              'Dislipidemia',                         'metabolico'),
    ('hipotiroidismo',            'Hipotiroidismo',                       'metabolico'),
    ('irc',                       'Insuficiencia renal crónica (IRC)',    'metabolico'),
    -- Respiratorio
    ('epoc',                      'Enfermedad pulmonar obstructiva crónica (EPOC)', 'respiratorio'),
    ('asma',                      'Asma',                                 'respiratorio'),
    ('lcfa',                      'Limitación crónica del flujo aéreo (LCFA)', 'respiratorio'),
    -- Osteomuscular
    ('artrosis_cadera',           'Artrosis de cadera',                   'osteomuscular'),
    ('artrosis_rodilla',          'Artrosis de rodillas',                 'osteomuscular'),
    ('poliartrosis',              'Poliartrosis',                         'osteomuscular'),
    ('lumbago_cronico',           'Lumbago crónico',                      'osteomuscular'),
    -- Neuropsiquiátrico
    ('deterioro_cognitivo',       'Deterioro cognitivo',                  'neuropsiquiatrico'),
    ('demencia_alzheimer',        'Demencia / enfermedad de Alzheimer',   'neuropsiquiatrico'),
    ('parkinson',                 'Enfermedad de Parkinson',              'neuropsiquiatrico'),
    ('depresion',                 'Depresión',                            'neuropsiquiatrico'),
    ('trastorno_ansioso',         'Trastorno ansioso depresivo',          'neuropsiquiatrico'),
    ('insomnio',                  'Insomnio / trastorno del sueño',       'neuropsiquiatrico'),
    -- Síndromes geriátricos
    ('caidas',                    'Caídas a repetición',                  'geriatrico'),
    ('polifarmacia',              'Polifarmacia',                         'geriatrico'),
    ('incontinencia_urinaria',    'Incontinencia urinaria',               'geriatrico'),
    ('inmovilidad',               'Inmovilidad',                          'geriatrico'),
    ('malnutricion',              'Malnutrición',                         'geriatrico'),
    ('alteracion_marcha',         'Alteración de la marcha',              'geriatrico'),
    ('ulceras_presion',           'Úlceras por presión',                  'geriatrico'),
    ('delirium',                  'Delirium',                             'geriatrico'),
    -- Sensorial
    ('hipoacusia',                'Hipoacusia',                           'sensorial'),
    ('cataratas',                 'Cataratas',                            'sensorial'),
    ('vicio_refraccion',          'Vicio de refracción',                  'sensorial'),
    ('retinopatia_diabetica',     'Retinopatía diabética',                'sensorial'),
    -- Otras
    ('dhc',                       'Daño hepático crónico (DHC)',          'otras'),
    ('colelitiasis',              'Colelitiasis',                         'otras'),
    ('patologia_oral',            'Patología oral',                       'otras');

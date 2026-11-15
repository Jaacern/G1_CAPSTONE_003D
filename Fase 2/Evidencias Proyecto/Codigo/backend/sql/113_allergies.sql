-- AgeCare — Bloque 1: Identidad y acceso
-- 113_allergies.sql — Alergias e intolerancias del paciente (Fase 6)
--
-- POR QUÉ (SEGURIDAD DEL PACIENTE)
--   Una alergia no reportada puede matar: prescribir penicilina a un alérgico,
--   darle pseudoefedrina, un marisco en la comida. La ficha del adulto mayor
--   debe registrar a qué es alérgico, con qué gravedad y cómo se supo. Y, lo
--   crítico: al prescribir un fármaco que coincide con una alergia, la app debe
--   ADVERTIR y exigir que el MÉDICO confirme (no la cuidadora) antes de seguir.
--
--   Las alergias se descubren en el tiempo: al registrar al paciente, por un
--   test de alergias posterior, o porque aparece una reacción durante un
--   tratamiento. Por eso es una LISTA que crece (como patient_conditions), con
--   baja lógica para conservar el histórico, no un campo del perfil.
--
--   Modelo:
--     · allergen_catalog: vocabulario semilla de alérgenos por categoría
--       (medicamento / alimento / ambiental / otra). Los de categoría
--       'medicamento' mapean a un active_ingredient para cruzar con drug_catalog.
--     · patient_allergies: alergias vigentes del paciente, con severidad,
--       reacción, cómo se supo (source) y cuándo (noted_on).
--
--   Decisión de diseño: el cruce con la prescripción es ADVERTENCIA con
--   confirmación del médico, no bloqueo duro. Así la responsabilidad clínica
--   queda en el médico (que puede tener razones para prescribir igual), y nunca
--   en la cuidadora. Ver docs/PLAN_IMPLEMENTACION_FICHA_CLINICA.md.
--
--   Fuente: estructura de antecedentes de la ficha EMPAM/CESFAM (alergias como
--   antecedente obligatorio) y principios de administración segura (los "5
--   correctos": verificar alergias antes de administrar). Ver bibliografía en
--   docs/MODELO_CLINICO_CASO_REAL.md.

-- ─────────────────────────────────────────────────────────────────
-- allergen_catalog — vocabulario semilla de alérgenos
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE allergen_catalog (
    code              varchar(40)  PRIMARY KEY,   -- ej. penicilina
    label             varchar(100) NOT NULL,      -- ej. Penicilina
    category          varchar(20)  NOT NULL,      -- medicamento|alimento|ambiental|otra
    -- Para alérgenos de medicamento: principio activo con el que se cruza el
    -- catálogo de fármacos (drug_catalog.active_ingredient). NULL si no aplica.
    active_ingredient varchar(100),

    CONSTRAINT ck_allergen_catalog_category CHECK (
        category IN ('medicamento', 'alimento', 'ambiental', 'otra')
    )
);

COMMENT ON TABLE allergen_catalog IS
    'Catálogo semilla de alérgenos por categoría. Los de categoría medicamento llevan active_ingredient para cruzar con drug_catalog y advertir en la prescripción. El médico puede escribir un alérgeno libre (queda en otra).';

INSERT INTO allergen_catalog (code, label, category, active_ingredient) VALUES
    -- Medicamentos (los de mayor riesgo y frecuencia en el adulto mayor)
    ('penicilina',     'Penicilina',                     'medicamento', 'Penicilina'),
    ('amoxicilina',    'Amoxicilina',                    'medicamento', 'Amoxicilina'),
    ('cefalosporinas', 'Cefalosporinas',                 'medicamento', 'Cefalosporina'),
    ('sulfas',         'Sulfas (sulfonamidas)',          'medicamento', 'Sulfametoxazol'),
    ('aines',          'AINEs (antiinflamatorios)',      'medicamento', 'Ibuprofeno'),
    ('aspirina',       'Ácido acetilsalicílico',         'medicamento', 'Ácido acetilsalicílico'),
    ('pseudoefedrina', 'Pseudoefedrina',                 'medicamento', 'Pseudoefedrina'),
    ('codeina',        'Codeína',                        'medicamento', 'Codeína'),
    ('tramadol',       'Tramadol',                       'medicamento', 'Tramadol'),
    ('metformina',     'Metformina',                     'medicamento', 'Metformina'),
    ('iodo_contraste', 'Medio de contraste yodado',      'medicamento', 'Yodo'),
    -- Alimentos
    ('mariscos',       'Mariscos',                       'alimento',    NULL),
    ('pescado',        'Pescado',                        'alimento',    NULL),
    ('frutos_secos',   'Frutos secos',                   'alimento',    NULL),
    ('mani',           'Maní',                           'alimento',    NULL),
    ('huevo',          'Huevo',                          'alimento',    NULL),
    ('leche',          'Leche / lactosa',                'alimento',    NULL),
    ('gluten',         'Gluten',                         'alimento',    NULL),
    -- Ambientales / otras
    ('latex',          'Látex',                          'ambiental',   NULL),
    ('picadura_abeja', 'Picadura de abeja/avispa',       'ambiental',   NULL),
    ('polen',          'Polen',                          'ambiental',   NULL),
    ('acaros',         'Ácaros del polvo',               'ambiental',   NULL);


-- ─────────────────────────────────────────────────────────────────
-- patient_allergies — alergias vigentes del paciente (lista que crece)
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE patient_allergies (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id  uuid         NOT NULL,
    substance   varchar(80)  NOT NULL,   -- code del catálogo o texto libre
    category    varchar(20)  NOT NULL DEFAULT 'otra',
    severity    varchar(20)  NOT NULL DEFAULT 'moderada',
    reaction    varchar(200),            -- descripción de la reacción (texto)
    source      varchar(20)  NOT NULL DEFAULT 'reportada',
    noted_on    date         NOT NULL DEFAULT CURRENT_DATE,  -- cuándo se supo
    recorded_by uuid,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    deleted_at  timestamptz,             -- baja lógica: conserva histórico

    CONSTRAINT fk_patient_allergies_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_patient_allergies_user
        FOREIGN KEY (recorded_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT ck_patient_allergies_category CHECK (
        category IN ('medicamento', 'alimento', 'ambiental', 'otra')
    ),
    CONSTRAINT ck_patient_allergies_severity CHECK (
        severity IN ('leve', 'moderada', 'severa', 'anafilaxia')
    ),
    CONSTRAINT ck_patient_allergies_source CHECK (
        source IN ('reportada', 'test', 'reaccion_tratamiento')
    )
);

-- Unicidad por sustancia vigente (índice PARCIAL, igual que patient_conditions).
CREATE UNIQUE INDEX ux_patient_allergy
    ON patient_allergies (patient_id, substance) WHERE deleted_at IS NULL;

CREATE INDEX ix_patient_allergies_patient
    ON patient_allergies (patient_id) WHERE deleted_at IS NULL;

COMMENT ON TABLE patient_allergies IS
    'Alergias/intolerancias vigentes del paciente. Lista que crece en el tiempo (al registrar, por test, o por reacción en tratamiento). Baja lógica para histórico. severity leve|moderada|severa|anafilaxia. source reportada|test|reaccion_tratamiento. Las de categoría medicamento se cruzan con drug_catalog para advertir en la prescripción.';
COMMENT ON COLUMN patient_allergies.substance IS 'Code del allergen_catalog o texto libre si no está catalogado.';
COMMENT ON COLUMN patient_allergies.source IS 'Cómo se supo: reportada (la dice el paciente/familia) | test (test de alergias) | reaccion_tratamiento (apareció durante un tratamiento).';
COMMENT ON COLUMN patient_allergies.noted_on IS 'Fecha en que se descubrió/registró la alergia (distinta de created_at).';


-- ─────────────────────────────────────────────────────────────────
-- patients.complexity — nivel de complejidad del paciente (atributo de perfil)
-- ─────────────────────────────────────────────────────────────────
-- "Paciente crónico de alta complejidad" no es una vacuna ni una alergia: es un
-- atributo del perfil, como el RCV. Define el nivel de seguimiento.
ALTER TABLE patients
    ADD COLUMN IF NOT EXISTS complexity varchar(15);

ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_complexity;
ALTER TABLE patients ADD CONSTRAINT ck_patients_complexity CHECK (
    complexity IS NULL OR complexity IN ('baja', 'moderada', 'alta')
);

COMMENT ON COLUMN patients.complexity IS
    'Nivel de complejidad del paciente: baja | moderada | alta. Un crónico de alta complejidad requiere seguimiento estrecho. NULL = no evaluado.';

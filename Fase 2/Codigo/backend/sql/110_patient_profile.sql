-- AgeCare — Bloque 1: Identidad y acceso
-- 110_patient_profile.sql — Perfil clínico ampliado del paciente (Fase 2)
--
-- POR QUÉ
--   La ficha real de un adulto mayor (EMPAM/CESFAM) incluye, además de nombre y
--   RUT: domicilio, estado civil, previsión (Fonasa/Isapre) y datos
--   antropométricos (peso, altura → IMC). También el nivel de riesgo
--   cardiovascular (RCV), que define metas terapéuticas (ver
--   docs/MODELO_CLINICO_CASO_REAL.md, consenso MINSAL 2014).
--
--   El peso cambia en el tiempo, así que NO va como columna de patients: va en
--   una tabla con historial (patient_measurements). La altura también se guarda
--   ahí por simplicidad, con el peso de cada control.

-- Campos estables del perfil, directo en patients.
ALTER TABLE patients
    ADD COLUMN IF NOT EXISTS address        varchar(200),
    ADD COLUMN IF NOT EXISTS marital_status varchar(20),
    ADD COLUMN IF NOT EXISTS insurance      varchar(20),
    ADD COLUMN IF NOT EXISTS rcv_level      varchar(10);

-- Estado civil: lista cerrada razonable (puede quedar NULL).
ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_marital_status;
ALTER TABLE patients ADD CONSTRAINT ck_patients_marital_status CHECK (
    marital_status IS NULL OR marital_status IN
        ('soltero','casado','viudo','divorciado','conviviente','separado')
);

-- Previsión de salud chilena.
ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_insurance;
ALTER TABLE patients ADD CONSTRAINT ck_patients_insurance CHECK (
    insurance IS NULL OR insurance IN ('fonasa','isapre','particular','otra')
);

-- Riesgo cardiovascular: 3 niveles vigentes (consenso MINSAL 2014). NULL = no evaluado.
ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_rcv_level;
ALTER TABLE patients ADD CONSTRAINT ck_patients_rcv_level CHECK (
    rcv_level IS NULL OR rcv_level IN ('bajo','moderado','alto')
);

COMMENT ON COLUMN patients.address IS 'Domicilio del paciente (texto). Para visitas y derivaciones.';
COMMENT ON COLUMN patients.marital_status IS 'Estado civil. Lista cerrada. Puede quedar NULL.';
COMMENT ON COLUMN patients.insurance IS 'Previsión de salud: fonasa | isapre | particular | otra.';
COMMENT ON COLUMN patients.rcv_level IS 'Nivel de riesgo cardiovascular (MINSAL 2014): bajo | moderado | alto. Define metas terapéuticas. NULL = no evaluado.';


-- ─────────────────────────────────────────────────────────────────
-- patient_measurements — antropometría con historial (peso, altura, IMC)
-- ─────────────────────────────────────────────────────────────────
-- El IMC es derivado (peso / altura²); se calcula en la aplicación al mostrar,
-- no se guarda, para no tener un dato que pueda quedar inconsistente.
CREATE TABLE patient_measurements (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id  uuid         NOT NULL,
    weight_kg   numeric(5,2),
    height_cm   numeric(5,1),
    measured_at date         NOT NULL DEFAULT CURRENT_DATE,
    recorded_by uuid,
    created_at  timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_patient_measurements_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_patient_measurements_user
        FOREIGN KEY (recorded_by) REFERENCES users(id) ON DELETE RESTRICT,
    -- Topes de cordura (seguridad): nadie pesa 500 kg ni mide 3 m.
    CONSTRAINT ck_patient_measurements_weight
        CHECK (weight_kg IS NULL OR (weight_kg > 0 AND weight_kg <= 400)),
    CONSTRAINT ck_patient_measurements_height
        CHECK (height_cm IS NULL OR (height_cm > 0 AND height_cm <= 260)),
    CONSTRAINT ck_patient_measurements_algo
        CHECK (weight_kg IS NOT NULL OR height_cm IS NOT NULL)
);

-- Última medición primero.
CREATE INDEX ix_patient_measurements_patient
    ON patient_measurements (patient_id, measured_at DESC);

COMMENT ON TABLE  patient_measurements IS
    'Mediciones antropométricas del paciente con historial (peso, altura). El IMC se calcula al mostrar (peso/altura²), no se almacena. El peso cambia en el tiempo: por eso es tabla y no columna de patients.';
COMMENT ON COLUMN patient_measurements.measured_at IS 'Fecha de la medición (del control), distinta de created_at.';
COMMENT ON COLUMN patient_measurements.recorded_by IS 'Quién registró la medición (profesional o cuidadora).';

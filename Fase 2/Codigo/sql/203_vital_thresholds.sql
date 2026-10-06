-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 3 de 3: vital_thresholds
--
-- Corrección 2FN:
--   · CHECK de type eliminado → FK a vital_types.code (catálogo centralizado).
--     Antes el mismo listado estaba duplicado en vital_readings y aquí.

CREATE TABLE vital_thresholds (
    id         uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid         NOT NULL,
    -- FK al catálogo: fuente única de verdad para tipos válidos
    type       varchar(16)  NOT NULL,
    min_value  numeric(8,2),
    max_value  numeric(8,2),
    updated_by uuid,
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_vital_thresholds_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_vital_thresholds_user
        FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE RESTRICT,
    -- FK al catálogo: reemplaza el CHECK de lista duplicada
    CONSTRAINT fk_vital_thresholds_type
        FOREIGN KEY (type) REFERENCES vital_types(code) ON DELETE RESTRICT,
    CONSTRAINT uq_vital_thresholds_patient_type
        UNIQUE (patient_id, type),
    CONSTRAINT ck_vital_thresholds_range
        CHECK (min_value IS NULL OR max_value IS NULL OR min_value < max_value),
    CONSTRAINT ck_vital_thresholds_at_least_one
        CHECK (min_value IS NOT NULL OR max_value IS NOT NULL)
);

CREATE TRIGGER tg_vital_thresholds_updated_at
    BEFORE UPDATE ON vital_thresholds
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  vital_thresholds IS
    'Rango normal de cada signo vital por paciente. Define cuándo una lectura dispara una alerta vital_out_of_range.';
COMMENT ON COLUMN vital_thresholds.type IS
    'Tipo de signo vital. FK a vital_types.code: reemplaza el CHECK de lista duplicada que existía en vital_readings y aquí.';
COMMENT ON COLUMN vital_thresholds.min_value IS
    'Límite inferior. NULL si el vital solo tiene techo (ej. temperatura).';
COMMENT ON COLUMN vital_thresholds.max_value IS
    'Límite superior. NULL si el vital solo tiene piso (ej. saturación O₂).';
COMMENT ON COLUMN vital_thresholds.updated_by IS
    'Quién configuró el umbral por última vez (RF-21). ON DELETE RESTRICT: se conserva el registro de quién lo definió.';

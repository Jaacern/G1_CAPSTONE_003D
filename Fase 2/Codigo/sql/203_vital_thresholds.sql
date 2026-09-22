-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 3 de 3: vital_thresholds

CREATE TABLE vital_thresholds (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
type varchar(16)  NOT NULL,
min_value numeric(8,2),
max_value numeric(8,2),
updated_by uuid,
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_vital_thresholds_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_vital_thresholds_user
    FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL,
CONSTRAINT uq_vital_thresholds_patient_type
    UNIQUE (patient_id, type),
CONSTRAINT ck_vital_thresholds_type
    CHECK (type IN ('heart_rate','spo2','sleep','steps','sedentary_min',
                    'fall_event','blood_pressure','temperature','glucose')),
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
    'Rango normal de cada signo vital, por paciente. Define cuándo una lectura dispara una alerta vital_out_of_range. Los valores por defecto para pacientes nuevos se configuran globalmente (ticket AGE-308).';
COMMENT ON COLUMN vital_thresholds.type IS
    'Tipo de signo vital. La lista se repite respecto de vital_readings a propósito: una clave foránea a un catálogo costaría una verificación por cada una de los millones de inserciones de lecturas.';
COMMENT ON COLUMN vital_thresholds.min_value IS
    'Límite inferior. NULL si ese vital solo tiene techo, como la temperatura.';
COMMENT ON COLUMN vital_thresholds.max_value IS
    'Límite superior. NULL si ese vital solo tiene piso, como la saturación de oxígeno.';
COMMENT ON COLUMN vital_thresholds.updated_by IS
    'Quién configuró el umbral por última vez, familiar o médico (RF-21). ON DELETE SET NULL: si borra su cuenta, el umbral sigue vigente.';

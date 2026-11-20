-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 4 de 6: patients
--
-- Correcciones 2FN aplicadas:
--   · full_name dividido en first_name + last_name (1FN: atomicidad)
--   · full_name se mantiene como columna GENERATED para compatibilidad con API y búsquedas
--   · conditions eliminado → tabla patient_conditions (1FN: no grupos repetidos)
--   · rut_dv documentado como dato derivado (módulo 11 de rut_number)

CREATE TABLE patients (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),

    -- 1FN: nombre y apellido son atributos distintos
    first_name  varchar(60)  NOT NULL,
    last_name   varchar(60)  NOT NULL,
    -- Columna calculada para compatibilidad con la API y búsquedas de texto
    full_name   varchar(121) GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,

    -- RUT: rut_dv es derivable de rut_number (módulo 11).
    -- Se almacena por conveniencia de validación; no es dato independiente.
    rut_number  integer,
    rut_dv      char(1),

    birth_date  date         NOT NULL,
    sex         char(1)      NOT NULL,
    photo_url   text,
    timezone    varchar(50)  NOT NULL DEFAULT 'America/Santiago',
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    deleted_at  timestamptz,

    CONSTRAINT ck_patients_first_name_min
        CHECK (char_length(first_name) >= 1),
    CONSTRAINT ck_patients_last_name_min
        CHECK (char_length(last_name) >= 1),
    CONSTRAINT ck_patients_sex
        CHECK (sex IN ('M','F','O')),
    CONSTRAINT ck_patients_birth_date
        CHECK (birth_date > '1900-01-01' AND birth_date <= CURRENT_DATE),
    CONSTRAINT ck_patients_rut_pair
        CHECK ((rut_number IS NULL) = (rut_dv IS NULL)),
    CONSTRAINT ck_patients_rut_number
        CHECK (rut_number IS NULL OR rut_number BETWEEN 1000000 AND 99999999),
    CONSTRAINT ck_patients_rut_dv
        CHECK (rut_dv IS NULL OR rut_dv ~ '^[0-9K]$')
);

-- Un RUT identifica a una persona. Solo entre los vigentes.
CREATE UNIQUE INDEX ux_patients_rut
    ON patients (rut_number) WHERE deleted_at IS NULL AND rut_number IS NOT NULL;

-- Búsqueda por nombre completo.
CREATE INDEX ix_patients_full_name
    ON patients (lower(full_name)) WHERE deleted_at IS NULL;

CREATE TRIGGER tg_patients_updated_at
    BEFORE UPDATE ON patients
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  patients IS
    'Adultos mayores de los que se lleva expediente. NO es un usuario: el paciente puede no tener cuenta. El vínculo entre personas y pacientes vive en patient_members.';
COMMENT ON COLUMN patients.first_name IS
    'Nombre(s) del adulto mayor. Separado de last_name para ordenar por apellido y generar saludos formales. 1FN: atomicidad.';
COMMENT ON COLUMN patients.last_name IS
    'Apellido(s) del adulto mayor. 1FN: atributo distinto de first_name.';
COMMENT ON COLUMN patients.full_name IS
    'Columna generada (first_name || last_name). Solo lectura. Mantiene compatibilidad con la API v1 y facilita búsquedas de texto completo.';
COMMENT ON COLUMN patients.rut_number IS
    'Número del RUT sin puntos ni dígito verificador. Entero para evitar duplicados por formato.';
COMMENT ON COLUMN patients.rut_dv IS
    'Dígito verificador (0-9 o K). Derivable de rut_number por módulo 11. Se almacena por conveniencia de validación, no como dato independiente.';
COMMENT ON COLUMN patients.birth_date IS
    'Fecha de nacimiento. La edad se calcula: date_part(''year'', age(birth_date)).';
COMMENT ON COLUMN patients.sex IS
    'M = masculino, F = femenino, O = otro.';
COMMENT ON COLUMN patients.timezone IS
    'Zona horaria IANA. Base del cálculo de horarios de medicación (RF-32). Por defecto America/Santiago.';
COMMENT ON COLUMN patients.deleted_at IS
    'Baja lógica. El expediente clínico nunca se borra físicamente.';


-- ─────────────────────────────────────────────────────────────────
-- patient_conditions
-- Normalización 1FN: reemplaza la columna conditions jsonb de patients.
-- Cada condición médica es una entidad con su propio ciclo de vida.
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE patient_conditions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id   uuid        NOT NULL,
    condition    varchar(80) NOT NULL,
    diagnosed_at date,
    created_at   timestamptz NOT NULL DEFAULT now(),
    -- Baja lógica: una condición corregida o remitida se desactiva, no se borra.
    -- Conserva el histórico clínico para analítica (p. ej. evolución de padecimientos).
    deleted_at   timestamptz,

    CONSTRAINT fk_patient_conditions_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT ck_patient_condition_min
        CHECK (char_length(condition) >= 2)
);

-- Unicidad solo entre condiciones vigentes: permite re-registrar una condición
-- que antes fue dada de baja, sin chocar con el histórico conservado.
CREATE UNIQUE INDEX ux_patient_condition
    ON patient_conditions (patient_id, condition) WHERE deleted_at IS NULL;

CREATE INDEX ix_patient_conditions_patient
    ON patient_conditions (patient_id) WHERE deleted_at IS NULL;

COMMENT ON TABLE  patient_conditions IS
    'Condiciones médicas del paciente. Normalización 1FN: reemplaza el arreglo JSON conditions que vivía en patients. Permite filtrar pacientes por padecimiento y agregar fecha de diagnóstico.';
COMMENT ON COLUMN patient_conditions.condition IS
    'Código o descripción del padecimiento (ej. hipertension, diabetes_tipo_2).';
COMMENT ON COLUMN patient_conditions.diagnosed_at IS
    'Fecha de diagnóstico. Opcional; no estaba disponible en el modelo anterior.';
COMMENT ON COLUMN patient_conditions.deleted_at IS
    'Baja lógica. Una condición corregida o remitida se desactiva; el histórico clínico se conserva para trazabilidad y analítica.';

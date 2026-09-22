
-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 4 de 6: patients


CREATE TABLE patients (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name   varchar(120) NOT NULL,
    rut_number  integer,
    rut_dv      char(1),
    birth_date  date         NOT NULL,
    sex         char(1)      NOT NULL,
    photo_url   text,
    conditions  jsonb        NOT NULL DEFAULT '[]'::jsonb,
    timezone    varchar(50)  NOT NULL DEFAULT 'America/Santiago',
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    deleted_at  timestamptz,

    CONSTRAINT ck_patients_full_name_min
        CHECK (char_length(full_name) >= 2),
    CONSTRAINT ck_patients_sex
        CHECK (sex IN ('M','F','O')),
    CONSTRAINT ck_patients_birth_date
        CHECK (birth_date > '1900-01-01' AND birth_date <= CURRENT_DATE),
    CONSTRAINT ck_patients_rut_pair
        CHECK ((rut_number IS NULL) = (rut_dv IS NULL)),
    CONSTRAINT ck_patients_rut_number
        CHECK (rut_number IS NULL OR rut_number BETWEEN 1000000 AND 99999999),
    CONSTRAINT ck_patients_rut_dv
        CHECK (rut_dv IS NULL OR rut_dv ~ '^[0-9K]$'),
    CONSTRAINT ck_patients_conditions_array
        CHECK (jsonb_typeof(conditions) = 'array')
);

-- Un RUT identifica a una persona. Solo entre los vigentes,
-- para que dar de baja y volver a crear no choque.
CREATE UNIQUE INDEX ux_patients_rut
    ON patients (rut_number) WHERE deleted_at IS NULL AND rut_number IS NOT NULL;

CREATE TRIGGER tg_patients_updated_at
    BEFORE UPDATE ON patients
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  patients IS
    'Adultos mayores de los que se lleva expediente. NO es un usuario: el paciente puede no tener cuenta. El vínculo entre personas y pacientes vive en patient_members.';
COMMENT ON COLUMN patients.rut_number IS
    'Número del RUT sin puntos ni dígito verificador. Se guarda como entero para que el formato de escritura no genere duplicados.';
COMMENT ON COLUMN patients.rut_dv IS
    'Dígito verificador, 0-9 o K. Separado del número porque se calcula desde él (módulo 11) y así puede validarse.';
COMMENT ON COLUMN patients.birth_date IS
    'Fecha de nacimiento. La edad NO se almacena, se calcula: date_part(''year'', age(birth_date)).';
COMMENT ON COLUMN patients.sex IS
    'M = masculino, F = femenino, O = otro.';
COMMENT ON COLUMN patients.conditions IS
    'Lista de padecimientos, como arreglo JSON. Se mantiene sin normalizar porque ningún endpoint de la v1 busca ni agrupa por padecimiento. Si esa necesidad aparece, se normaliza en una tabla aparte.';
COMMENT ON COLUMN patients.timezone IS
    'Zona horaria IANA del paciente. Base del cálculo de horarios de medicación (RF-32). Por defecto America/Santiago.';
COMMENT ON COLUMN patients.deleted_at IS
    'Baja lógica. El expediente clínico nunca se borra físicamente.';
COMMENT ON COLUMN patients.id IS
    'Identificador interno del paciente.';
COMMENT ON COLUMN patients.full_name IS
    'Nombre completo del adulto mayor, 2 a 120 caracteres.';
COMMENT ON COLUMN patients.photo_url IS
    'Foto del paciente. Opcional.';
COMMENT ON COLUMN patients.created_at IS
    'Fecha de creación del expediente.';
COMMENT ON COLUMN patients.updated_at IS
    'Última modificación. La mantiene el trigger tg_patients_updated_at.';

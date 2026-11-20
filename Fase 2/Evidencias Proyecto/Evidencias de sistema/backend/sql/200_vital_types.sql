-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 0 de 3: vital_types  (catálogo)
--
-- Corrección 2FN:
--   · Centraliza el dominio de tipos de vitales que antes estaba duplicado
--     como CHECK idéntico en vital_readings y vital_thresholds.
--   · Agrega metadatos (unidad, si admite valor secundario) que antes vivían
--     hardcodeados en el código Python (dict UNITS en vitals.py).

CREATE TABLE vital_types (
    code          varchar(16)  PRIMARY KEY,
    label         varchar(60)  NOT NULL,
    unit          varchar(10)  NOT NULL DEFAULT '',
    has_secondary boolean      NOT NULL DEFAULT false,

    CONSTRAINT ck_vital_types_code_min
        CHECK (char_length(code) >= 2)
);

INSERT INTO vital_types (code, label, unit, has_secondary) VALUES
    ('heart_rate',    'Frecuencia cardíaca', 'bpm',    false),
    ('spo2',          'Saturación O₂',       '%',      false),
    ('sleep',         'Sueño',               'h',      false),
    ('steps',         'Pasos',               'pasos',  false),
    ('sedentary_min', 'Tiempo sedentario',   'min',    false),
    ('fall_event',    'Evento de caída',     '',       false),
    ('blood_pressure','Presión arterial',    'mmHg',   true),
    ('temperature',   'Temperatura',         '°C',     false),
    ('glucose',       'Glucosa',             'mg/dL',  false);

COMMENT ON TABLE  vital_types IS
    'Catálogo de tipos de signos vitales. Fuente única de verdad: reemplaza los CHECK duplicados en vital_readings y vital_thresholds. Agregar un nuevo tipo aquí lo habilita automáticamente en todo el sistema.';
COMMENT ON COLUMN vital_types.code IS
    'Identificador corto usado en la API y en las tablas de mediciones.';
COMMENT ON COLUMN vital_types.unit IS
    'Unidad de presentación. Reemplaza el dict UNITS hardcodeado en vitals.py.';
COMMENT ON COLUMN vital_types.has_secondary IS
    'true solo para blood_pressure (sistólica + diastólica). Usado por el CHECK ck_vital_readings_secondary.';

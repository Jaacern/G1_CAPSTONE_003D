-- AgeCare — Bloque 9: Marketplace
-- Tabla 1 de 9: specialties

CREATE TABLE specialties (
    code        varchar(40)  PRIMARY KEY,
    label       varchar(80)  NOT NULL,
    description varchar(300),
    created_at  timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT ck_specialties_code CHECK (code ~ '^[a-z][a-z0-9_]{2,39}$'),
    CONSTRAINT ck_specialties_label CHECK (btrim(label) <> '')
);

COMMENT ON TABLE  specialties IS
    'Catálogo de especialidades de cuidado. Fuente única de verdad para el filtro de búsqueda de cuidadoras. RF-72, RF-75.';
COMMENT ON COLUMN specialties.code IS
    'Código estable de la especialidad, por ejemplo alzheimer o movilidad_reducida. Es lo que consulta la aplicación.';
COMMENT ON COLUMN specialties.label IS
    'Nombre visible de la especialidad.';
COMMENT ON COLUMN specialties.description IS
    'Explicación de qué abarca la especialidad, para la pantalla de búsqueda.';
COMMENT ON COLUMN specialties.created_at IS
    'Fecha de creación del registro.';

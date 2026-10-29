-- AgeCare — Bloque 9: Marketplace
-- Tabla 3 de 9: caregiver_specialties


CREATE TABLE caregiver_specialties (
    profile_id     uuid        NOT NULL,
    specialty_code varchar(40) NOT NULL,
    years          smallint,
    created_at     timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (profile_id, specialty_code),

    CONSTRAINT fk_caregiver_specialties_profile
        FOREIGN KEY (profile_id) REFERENCES caregiver_profiles(id) ON DELETE RESTRICT,
    CONSTRAINT fk_caregiver_specialties_specialty
        FOREIGN KEY (specialty_code) REFERENCES specialties(code) ON DELETE RESTRICT,

    CONSTRAINT ck_caregiver_specialties_years
        CHECK (years IS NULL OR years BETWEEN 0 AND 70)
);

-- RF-75: la búsqueda va al revés, dada una especialidad, qué perfiles la tienen.
CREATE INDEX ix_caregiver_specialties_specialty
    ON caregiver_specialties (specialty_code, profile_id);

COMMENT ON TABLE  caregiver_specialties IS
    'Especialidades declaradas por cada cuidadora. Normalización 1FN: reemplaza lo que sería una lista dentro del perfil. RF-72, RF-75.';
COMMENT ON COLUMN caregiver_specialties.profile_id IS
    'Perfil que declara la especialidad.';
COMMENT ON COLUMN caregiver_specialties.specialty_code IS
    'Especialidad declarada. Apunta al catálogo, así que no se puede inventar una.';
COMMENT ON COLUMN caregiver_specialties.years IS
    'Años de experiencia en esa especialidad en particular. Opcional.';
COMMENT ON COLUMN caregiver_specialties.created_at IS
    'Fecha de creación del registro.';

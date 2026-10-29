-- AgeCare — Bloque 9: Marketplace
-- Tabla 4 de 9: caregiver_languages


CREATE TABLE caregiver_languages (
    profile_id    uuid        NOT NULL,
    language_code char(2)     NOT NULL,
    proficiency   varchar(12) NOT NULL DEFAULT 'conversational',
    created_at    timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (profile_id, language_code),

    CONSTRAINT fk_caregiver_languages_profile
        FOREIGN KEY (profile_id) REFERENCES caregiver_profiles(id) ON DELETE RESTRICT,

    CONSTRAINT ck_caregiver_languages_code CHECK (language_code ~ '^[a-z]{2}$'),
    CONSTRAINT ck_caregiver_languages_nivel CHECK (
        proficiency IN ('basic','conversational','fluent','native')
    )
);

-- RF-75: qué perfiles hablan un idioma dado.
CREATE INDEX ix_caregiver_languages_code
    ON caregiver_languages (language_code, profile_id);

COMMENT ON TABLE  caregiver_languages IS
    'Idiomas que habla cada cuidadora, uno por fila. Normalización 1FN. RF-72, RF-75.';
COMMENT ON COLUMN caregiver_languages.profile_id IS
    'Perfil que declara el idioma.';
COMMENT ON COLUMN caregiver_languages.language_code IS
    'Código ISO 639-1 de dos letras. El nombre visible lo resuelve la aplicación.';
COMMENT ON COLUMN caregiver_languages.proficiency IS
    'Nivel declarado: basic, conversational, fluent o native.';
COMMENT ON COLUMN caregiver_languages.created_at IS
    'Fecha de creación del registro.';

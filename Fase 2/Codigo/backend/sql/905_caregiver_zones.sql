-- AgeCare — Bloque 9: Marketplace
-- Tabla 5 de 9: caregiver_zones

CREATE TABLE caregiver_zones (
    profile_id    uuid        NOT NULL,
    commune_code  char(5)     NOT NULL,
    travel_fee    numeric(12,2),
    created_at    timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (profile_id, commune_code),

    CONSTRAINT fk_caregiver_zones_profile
        FOREIGN KEY (profile_id) REFERENCES caregiver_profiles(id) ON DELETE RESTRICT,

    CONSTRAINT ck_caregiver_zones_code CHECK (commune_code ~ '^[0-9]{5}$'),
    CONSTRAINT ck_caregiver_zones_fee CHECK (travel_fee IS NULL OR travel_fee >= 0)
);

-- RF-75: qué cuidadoras atienden una comuna. Es el filtro más usado de la búsqueda.
CREATE INDEX ix_caregiver_zones_comuna
    ON caregiver_zones (commune_code, profile_id);

COMMENT ON TABLE  caregiver_zones IS
    'Comunas donde atiende cada cuidadora, una por fila. Normalización 1FN. Guarda solo el código oficial, no el nombre, para no incurrir en dependencia transitiva. RF-72, RF-75.';
COMMENT ON COLUMN caregiver_zones.profile_id IS
    'Perfil que atiende la comuna.';
COMMENT ON COLUMN caregiver_zones.commune_code IS
    'Código de comuna del INE, cinco dígitos. El nombre lo resuelve la aplicación contra la lista oficial.';
COMMENT ON COLUMN caregiver_zones.travel_fee IS
    'Recargo por traslado a esa comuna, si cobra uno.';
COMMENT ON COLUMN caregiver_zones.created_at IS
    'Fecha de creación del registro.';

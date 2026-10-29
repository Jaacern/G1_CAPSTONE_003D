-- AgeCare — Bloque 9: Marketplace
-- Tabla 2 de 9: caregiver_profiles


CREATE TABLE caregiver_profiles (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid          NOT NULL,
    headline          varchar(120)  NOT NULL,
    bio               varchar(2000),
    years_experience  smallint      NOT NULL DEFAULT 0,
    hourly_rate       numeric(12,2),
    currency          char(3)       NOT NULL DEFAULT 'CLP',
    availability      varchar(12)   NOT NULL DEFAULT 'part_time',
    accepts_overnight boolean       NOT NULL DEFAULT false,
    status            varchar(12)   NOT NULL DEFAULT 'draft',
    rating_avg        numeric(3,2),
    rating_count      integer       NOT NULL DEFAULT 0,
    published_at      timestamptz,
    suspended_at      timestamptz,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    deleted_at        timestamptz,

    CONSTRAINT fk_caregiver_profiles_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,

    -- Una persona tiene un solo perfil profesional.
    CONSTRAINT uq_caregiver_profiles_user UNIQUE (user_id),
    -- Necesaria para que caregiver_reviews pueda amarrar, con una sola clave
    -- foránea compuesta, que el perfil reseñado y el usuario reseñado sean el mismo.
    CONSTRAINT uq_caregiver_profiles_id_user UNIQUE (id, user_id),

    CONSTRAINT ck_caregiver_profiles_headline CHECK (btrim(headline) <> ''),
    CONSTRAINT ck_caregiver_profiles_experiencia
        CHECK (years_experience BETWEEN 0 AND 70),
    CONSTRAINT ck_caregiver_profiles_tarifa
        CHECK (hourly_rate IS NULL OR hourly_rate >= 0),
    CONSTRAINT ck_caregiver_profiles_currency CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT ck_caregiver_profiles_disponibilidad CHECK (
        availability IN ('full_time','part_time','hourly','live_in','weekends')
    ),
    CONSTRAINT ck_caregiver_profiles_status CHECK (
        status IN ('draft','published','suspended')
    ),
    -- Un perfil publicado tiene fecha de publicación; uno suspendido, de suspensión.
    CONSTRAINT ck_caregiver_profiles_status_fechas CHECK (
        (status = 'draft'     AND published_at IS NULL     AND suspended_at IS NULL)
     OR (status = 'published' AND published_at IS NOT NULL AND suspended_at IS NULL)
     OR (status = 'suspended' AND published_at IS NOT NULL AND suspended_at IS NOT NULL)
    ),
    CONSTRAINT ck_caregiver_profiles_rating
        CHECK (rating_avg IS NULL OR rating_avg BETWEEN 1 AND 5),
    CONSTRAINT ck_caregiver_profiles_rating_count CHECK (rating_count >= 0),
    -- O hay reseñas y hay promedio, o no hay ninguna de las dos. Impide que el
    -- promedio quede colgado sin reseñas que lo respalden.
    CONSTRAINT ck_caregiver_profiles_rating_par
        CHECK ((rating_avg IS NULL) = (rating_count = 0))
);

-- RF-75: la búsqueda recorre los perfiles publicados y los ordena por calificación.
CREATE INDEX ix_caregiver_profiles_busqueda
    ON caregiver_profiles (rating_avg DESC NULLS LAST, rating_count DESC)
    WHERE status = 'published' AND deleted_at IS NULL;

CREATE TRIGGER tg_caregiver_profiles_updated_at
    BEFORE UPDATE ON caregiver_profiles
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  caregiver_profiles IS
    'Perfil profesional de una cuidadora en el marketplace. Separado de users porque la mayoría de los usuarios nunca tiene perfil profesional. Sus listas (especialidades, idiomas, zonas, certificaciones) viven en tablas aparte por 1FN. RF-72, RF-76.';
COMMENT ON COLUMN caregiver_profiles.id IS
    'Identificador del perfil.';
COMMENT ON COLUMN caregiver_profiles.user_id IS
    'Usuario dueño del perfil. Único: una persona tiene un solo perfil profesional.';
COMMENT ON COLUMN caregiver_profiles.headline IS
    'Titular corto que resume la oferta, por ejemplo Cuidadora con 8 años en demencias.';
COMMENT ON COLUMN caregiver_profiles.bio IS
    'Presentación extendida que lee el familiar en el perfil público.';
COMMENT ON COLUMN caregiver_profiles.years_experience IS
    'Años de experiencia declarados.';
COMMENT ON COLUMN caregiver_profiles.hourly_rate IS
    'Tarifa por hora de referencia. Nula si prefiere conversarla.';
COMMENT ON COLUMN caregiver_profiles.currency IS
    'Moneda de la tarifa, en código ISO de tres letras.';
COMMENT ON COLUMN caregiver_profiles.availability IS
    'Modalidad de disponibilidad declarada.';
COMMENT ON COLUMN caregiver_profiles.accepts_overnight IS
    'Si acepta turnos de noche.';
COMMENT ON COLUMN caregiver_profiles.status IS
    'Estado del perfil: draft, published o suspended. Solo los published salen en la búsqueda.';
COMMENT ON COLUMN caregiver_profiles.rating_avg IS
    'Promedio de calificación. Valor DERIVADO de caregiver_reviews, almacenado para que RF-75 pueda ordenar sin recalcular. Lo mantiene un trigger, no la aplicación.';
COMMENT ON COLUMN caregiver_profiles.rating_count IS
    'Cantidad de reseñas vigentes. También derivado y mantenido por el mismo trigger.';
COMMENT ON COLUMN caregiver_profiles.published_at IS
    'Momento en que el perfil quedó visible en el marketplace.';
COMMENT ON COLUMN caregiver_profiles.suspended_at IS
    'Momento en que el perfil se suspendió. La fila se conserva.';
COMMENT ON COLUMN caregiver_profiles.created_at IS
    'Fecha de creación del registro.';
COMMENT ON COLUMN caregiver_profiles.updated_at IS
    'Fecha de la última modificación del registro.';
COMMENT ON COLUMN caregiver_profiles.deleted_at IS
    'Baja lógica. El perfil se conserva porque hay reseñas y solicitudes que lo referencian.';

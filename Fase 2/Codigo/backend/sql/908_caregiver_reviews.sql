-- AgeCare — Bloque 9: Marketplace
-- Tabla 8 de 9: caregiver_reviews


CREATE TABLE caregiver_reviews (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id       uuid          NOT NULL,
    reviewed_user_id uuid          NOT NULL,
    author_id        uuid          NOT NULL,
    patient_id       uuid          NOT NULL,
    rating           smallint      NOT NULL,
    comment          varchar(1000),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    deleted_at       timestamptz,

    -- El usuario reseñado es efectivamente el dueño de ese perfil.
    CONSTRAINT fk_caregiver_reviews_profile
        FOREIGN KEY (profile_id, reviewed_user_id)
        REFERENCES caregiver_profiles(id, user_id) ON DELETE RESTRICT,
    -- RF-78: el autor estuvo en el círculo de cuidado de ese paciente.
    CONSTRAINT fk_caregiver_reviews_autor_del_circulo
        FOREIGN KEY (patient_id, author_id)
        REFERENCES patient_members(patient_id, user_id) ON DELETE RESTRICT,
    -- RF-78: la cuidadora también estuvo en el círculo de ese paciente.
    CONSTRAINT fk_caregiver_reviews_cuidadora_del_circulo
        FOREIGN KEY (patient_id, reviewed_user_id)
        REFERENCES patient_members(patient_id, user_id) ON DELETE RESTRICT,

    -- RF-78: una sola reseña por persona y cuidadora.
    CONSTRAINT uq_caregiver_reviews_autor UNIQUE (profile_id, author_id),

    CONSTRAINT ck_caregiver_reviews_rating CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT ck_caregiver_reviews_no_autoresena
        CHECK (author_id <> reviewed_user_id),
    CONSTRAINT ck_caregiver_reviews_comentario
        CHECK (comment IS NULL OR btrim(comment) <> '')
);

-- RF-76: las reseñas vigentes de un perfil, de la más nueva a la más vieja.
CREATE INDEX ix_caregiver_reviews_perfil
    ON caregiver_reviews (profile_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TRIGGER tg_caregiver_reviews_updated_at
    BEFORE UPDATE ON caregiver_reviews
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- Mantenimiento del promedio almacenado en caregiver_profiles.
-- Recalcula sobre las reseñas vigentes cada vez que una cambia, así el valor
-- derivado no puede quedar desincronizado del dato real.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION caregiver_reviews_refresh_rating()
RETURNS TRIGGER AS $$
DECLARE
    pid uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        pid := OLD.profile_id;
    ELSE
        pid := NEW.profile_id;
    END IF;

    UPDATE caregiver_profiles p
       SET rating_count = s.n,
           rating_avg   = CASE WHEN s.n = 0 THEN NULL ELSE round(s.prom, 2) END
      FROM (SELECT count(*) AS n, avg(rating) AS prom
              FROM caregiver_reviews
             WHERE profile_id = pid AND deleted_at IS NULL) s
     WHERE p.id = pid;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION caregiver_reviews_refresh_rating() IS
    'Recalcula rating_avg y rating_count del perfil a partir de sus reseñas vigentes.';

CREATE TRIGGER tg_caregiver_reviews_rating
    AFTER INSERT OR UPDATE OR DELETE ON caregiver_reviews
    FOR EACH ROW
    EXECUTE FUNCTION caregiver_reviews_refresh_rating();

COMMENT ON TABLE  caregiver_reviews IS
    'Reseñas que dejan los familiares a las cuidadoras. Las dos condiciones de RF-78, una sola vez y solo quien la tuvo en su círculo, las impone el motor con un UNIQUE y dos claves foráneas compuestas contra patient_members. RF-76, RF-78.';
COMMENT ON COLUMN caregiver_reviews.id IS
    'Identificador de la reseña.';
COMMENT ON COLUMN caregiver_reviews.profile_id IS
    'Perfil reseñado.';
COMMENT ON COLUMN caregiver_reviews.reviewed_user_id IS
    'Usuario dueño de ese perfil. Se guarda para poder verificar contra patient_members que la cuidadora estuvo en el círculo.';
COMMENT ON COLUMN caregiver_reviews.author_id IS
    'Usuario que escribe la reseña.';
COMMENT ON COLUMN caregiver_reviews.patient_id IS
    'Círculo de cuidado en el que compartieron. Es la pieza que permite verificar RF-78.';
COMMENT ON COLUMN caregiver_reviews.rating IS
    'Calificación de 1 a 5.';
COMMENT ON COLUMN caregiver_reviews.comment IS
    'Texto de la reseña. Opcional, pero si viene no puede estar en blanco.';
COMMENT ON COLUMN caregiver_reviews.created_at IS
    'Fecha de creación del registro.';
COMMENT ON COLUMN caregiver_reviews.updated_at IS
    'Fecha de la última modificación del registro.';
COMMENT ON COLUMN caregiver_reviews.deleted_at IS
    'Baja lógica. La reseña se conserva y deja de contar en el promedio.';

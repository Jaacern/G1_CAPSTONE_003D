-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 703_plan_features.sql — Que funcionalidades incluye cada plan
-- Requisitos: RF-73, RF-83 a RF-85
-- ----------------------------------------------------------------------------
-- Tabla puente de la relacion muchos a muchos entre plans y features. Es el
-- corazon del constructor de planes: armar un plan es marcar funcionalidades
-- en esta tabla.
--
-- La PK es compuesta (plan_id, feature_code) y no hay uuid de sobra. Un
-- surrogate aqui no aportaria nada: la pareja ya identifica la fila de forma
-- unica y agregar una columna artificial permitiria insertar la misma pareja
-- dos veces, que es justo lo que hay que impedir. Es el ejemplo de 2FN que
-- vale mostrar: todo atributo no clave depende de la clave completa.
-- ============================================================================

CREATE TABLE plan_features (
    plan_id      uuid        NOT NULL,
    feature_code varchar(40) NOT NULL,
    is_included  boolean     NOT NULL DEFAULT true,
    note         varchar(200),
    created_at   timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (plan_id, feature_code),

    CONSTRAINT fk_plan_features_plan
        FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE RESTRICT,
    CONSTRAINT fk_plan_features_feature
        FOREIGN KEY (feature_code) REFERENCES features(code) ON DELETE RESTRICT
);

-- La consulta que importa en RF-73 va al revés: dada una funcionalidad,
-- en que planes esta incluida.
CREATE INDEX ix_plan_features_feature
    ON plan_features (feature_code)
    WHERE is_included;

COMMENT ON TABLE  plan_features IS 'Relacion entre planes y funcionalidades. Define que incluye cada plan y es lo que responde si una funcion esta habilitada. RF-73, RF-83 a RF-85.';
COMMENT ON COLUMN plan_features.plan_id IS 'Plan al que se le asigna la funcionalidad.';
COMMENT ON COLUMN plan_features.feature_code IS 'Funcionalidad asignada.';
COMMENT ON COLUMN plan_features.is_included IS 'Verdadero si el plan incluye la funcionalidad. Falso permite excluirla de forma explicita.';
COMMENT ON COLUMN plan_features.note IS 'Aclaracion sobre el alcance con que se incluye, si corresponde.';
COMMENT ON COLUMN plan_features.created_at IS 'Fecha de creacion del registro.';

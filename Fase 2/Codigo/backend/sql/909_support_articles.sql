-- AgeCare — Bloque 9: Marketplace
-- Tabla 9 de 9: support_articles


CREATE TABLE support_articles (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    category        varchar(24)   NOT NULL,
    name            varchar(120)  NOT NULL,
    description     varchar(1000) NOT NULL,
    reference_price numeric(12,2),
    currency        char(3)       NOT NULL DEFAULT 'CLP',
    external_url    text,
    image_url       text,
    is_featured     boolean       NOT NULL DEFAULT false,
    display_order   integer       NOT NULL DEFAULT 0,
    created_by      uuid,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    deleted_at      timestamptz,

    CONSTRAINT fk_support_articles_created_by
        FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT ck_support_articles_category CHECK (
        category IN ('mobility','bathroom','bedroom','hearing','vision',
                     'medication','daily_living','safety','cognition','other')
    ),
    CONSTRAINT ck_support_articles_name CHECK (btrim(name) <> ''),
    CONSTRAINT ck_support_articles_description CHECK (btrim(description) <> ''),
    CONSTRAINT ck_support_articles_price
        CHECK (reference_price IS NULL OR reference_price >= 0),
    CONSTRAINT ck_support_articles_currency CHECK (currency ~ '^[A-Z]{3}$'),
    -- Los enlaces salen al navegador del usuario, así que se exige https.
    CONSTRAINT ck_support_articles_external_url
        CHECK (external_url IS NULL OR external_url ~ '^https://'),
    CONSTRAINT ck_support_articles_image_url
        CHECK (image_url IS NULL OR image_url ~ '^https://')
);

-- Dos artículos distintos pueden llamarse igual en categorías distintas, pero no
-- dentro de la misma. Solo entre los vigentes.
CREATE UNIQUE INDEX ux_support_articles_nombre
    ON support_articles (category, lower(name))
    WHERE deleted_at IS NULL;

-- RF-79: el catálogo filtrado por categoría, que es la consulta del requisito.
CREATE INDEX ix_support_articles_categoria
    ON support_articles (category, display_order)
    WHERE deleted_at IS NULL;

-- Los destacados de la portada del catálogo.
CREATE INDEX ix_support_articles_destacados
    ON support_articles (display_order)
    WHERE is_featured AND deleted_at IS NULL;

CREATE TRIGGER tg_support_articles_updated_at
    BEFORE UPDATE ON support_articles
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  support_articles IS
    'Catálogo compartido de artículos de apoyo al cuidado, agrupados por categoría. No pertenece a ningún paciente ni perfil, y no gestiona stock ni ventas: informa qué existe y dónde conseguirlo. RF-79.';
COMMENT ON COLUMN support_articles.id IS
    'Identificador del artículo.';
COMMENT ON COLUMN support_articles.category IS
    'Categoría del artículo. Lista cerrada, porque RF-79 filtra por ella.';
COMMENT ON COLUMN support_articles.name IS
    'Nombre del artículo.';
COMMENT ON COLUMN support_articles.description IS
    'Para qué sirve y en qué casos se recomienda.';
COMMENT ON COLUMN support_articles.reference_price IS
    'Precio de referencia orientativo. No es un precio de venta de AgeCare.';
COMMENT ON COLUMN support_articles.currency IS
    'Moneda del precio de referencia, en código ISO de tres letras.';
COMMENT ON COLUMN support_articles.external_url IS
    'Enlace externo donde conseguirlo. Solo https.';
COMMENT ON COLUMN support_articles.image_url IS
    'Imagen del artículo. Va como URL y no como file_id porque files exige un paciente.';
COMMENT ON COLUMN support_articles.is_featured IS
    'Si aparece destacado en la portada del catálogo.';
COMMENT ON COLUMN support_articles.display_order IS
    'Orden de aparición dentro de su categoría.';
COMMENT ON COLUMN support_articles.created_by IS
    'Quién lo cargó al catálogo.';
COMMENT ON COLUMN support_articles.created_at IS
    'Fecha de creación del registro.';
COMMENT ON COLUMN support_articles.updated_at IS
    'Fecha de la última modificación del registro.';
COMMENT ON COLUMN support_articles.deleted_at IS
    'Baja lógica. El artículo se conserva aunque deje de ofrecerse.';

-- AgeCare — Marketplace
-- 925_market_products.sql — El catalogo de ayudas tecnicas
--
-- La pantalla del marketplace tiene una pestana de productos: andadores,
-- sillas de ruedas, barras de apoyo, panales, camas clinicas. Las pide con
-- filtro por categoria y abre el detalle de cada una. No habia tabla.
--
-- No es un comercio. AgeCare no cobra, no tiene carro ni despacho: muestra
-- que existe, cuanto cuesta aproximadamente y donde conseguirlo, que es lo
-- que una familia necesita cuando le dicen que su madre ya no puede subir
-- sola la escalera. Por eso hay precio referencial y proveedor, y no hay
-- stock ni pedidos.

CREATE TABLE market_products (
    id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),

    name           varchar(120) NOT NULL,
    description    varchar(1000) NOT NULL,
    category       varchar(20)  NOT NULL,

    -- Precio de referencia en pesos. numeric y no float: el dinero no se
    -- guarda en coma flotante.
    price          numeric(12,2),
    currency       char(3)      NOT NULL DEFAULT 'CLP',

    -- Donde conseguirlo. Es informacion, no un enlace de compra.
    supplier       varchar(120),
    supplier_url   varchar(300),

    image_file_id  uuid,
    image_scope    varchar(12),

    status         varchar(12)  NOT NULL DEFAULT 'draft',
    published_at   timestamptz,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now(),
    deleted_at     timestamptz,

    -- La imagen es del catalogo, no del expediente de nadie. La clave
    -- compuesta contra files(id, scope) hace que el motor lo garantice:
    -- no se puede colgar aca la foto del expediente de un paciente.
    CONSTRAINT fk_market_products_image
        FOREIGN KEY (image_file_id, image_scope)
        REFERENCES files(id, scope) ON DELETE RESTRICT,
    CONSTRAINT ck_market_products_image_scope CHECK (
        (image_file_id IS NULL AND image_scope IS NULL)
     OR (image_file_id IS NOT NULL AND image_scope = 'catalog')
    ),

    CONSTRAINT ck_market_products_category CHECK (
        category IN ('mobility', 'bathroom', 'bedroom', 'hygiene',
                     'monitoring', 'nutrition', 'other')
    ),
    CONSTRAINT ck_market_products_name  CHECK (btrim(name) <> ''),
    CONSTRAINT ck_market_products_desc  CHECK (btrim(description) <> ''),
    CONSTRAINT ck_market_products_price CHECK (price IS NULL OR price >= 0),
    CONSTRAINT ck_market_products_currency CHECK (currency ~ '^[A-Z]{3}$'),

    CONSTRAINT ck_market_products_status CHECK (
        status IN ('draft', 'published', 'discontinued')
    ),
    -- Un producto publicado tiene fecha de publicacion, igual que en
    -- caregiver_profiles. Los estados no quedan a medias.
    CONSTRAINT ck_market_products_status_fecha CHECK (
        (status = 'draft'        AND published_at IS NULL)
     OR (status <> 'draft'       AND published_at IS NOT NULL)
    ),
    -- Si hay enlace del proveedor, tiene que haber proveedor.
    CONSTRAINT ck_market_products_proveedor CHECK (
        supplier_url IS NULL OR supplier IS NOT NULL
    )
);

-- La pantalla pide el catalogo publicado filtrando por categoria.
CREATE INDEX ix_market_products_catalogo
    ON market_products (category, name)
    WHERE status = 'published' AND deleted_at IS NULL;

CREATE TRIGGER tg_market_products_updated_at
    BEFORE UPDATE ON market_products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE market_products IS
    'Catalogo de ayudas tecnicas del marketplace. Es informativo: precio referencial y donde conseguirlo, sin stock ni pedidos, porque AgeCare no vende.';
COMMENT ON COLUMN market_products.price IS
    'Precio de referencia, puede ser NULL cuando depende del proveedor.';

-- Datos de ejemplo para que la pantalla tenga que mostrar.
INSERT INTO market_products (name, description, category, price, supplier, status, published_at)
VALUES
 ('Andador plegable con ruedas',
  'Andador de aluminio con dos ruedas delanteras y regulacion de altura. Soporta hasta 100 kg y se pliega para guardarlo o llevarlo en auto.',
  'mobility', 45990, 'Ortopedia Biobio', 'published', now()),
 ('Silla de ruedas estandar',
  'Silla plegable de acero con apoyapies desmontables y frenos en ambas ruedas. Para uso domiciliario y traslados cortos.',
  'mobility', 139990, 'Ortopedia Biobio', 'published', now()),
 ('Barra de apoyo para ducha',
  'Barra de sujecion de 60 cm con ventosas de presion, para instalar sin perforar. Reduce el riesgo de caida en el bano, que es donde mas ocurren.',
  'bathroom', 18990, 'Casa del Adulto Mayor', 'published', now()),
 ('Silla de ducha con respaldo',
  'Asiento plastico con patas antideslizantes y altura regulable, para quienes no pueden mantenerse de pie durante el bano.',
  'bathroom', 32990, 'Casa del Adulto Mayor', 'published', now()),
 ('Cama clinica manual de 2 movimientos',
  'Cama con respaldo y piernas regulables con manivela, barandas laterales abatibles y ruedas con freno.',
  'bedroom', 389990, 'Equipamiento Medico Sur', 'published', now()),
 ('Colchon antiescaras de aire',
  'Colchon alternante con compresor silencioso, para prevenir ulceras por presion en personas postradas.',
  'bedroom', 89990, 'Equipamiento Medico Sur', 'published', now()),
 ('Panales para adulto, talla M',
  'Paquete de 20 unidades con alta absorcion y banda elastica. Talla M, contorno de cadera 80 a 120 cm.',
  'hygiene', 12990, NULL, 'published', now()),
 ('Pastillero semanal con alarma',
  'Organizador de 7 dias con 4 tomas diarias y alarma sonora programable, para no saltarse ni repetir una dosis.',
  'monitoring', 24990, NULL, 'published', now()),
 ('Tensiometro digital de brazo',
  'Monitor automatico de presion arterial con memoria para dos usuarios y deteccion de arritmia.',
  'monitoring', 39990, 'Farmacias del Sur', 'published', now()),
 ('Espesante alimentario neutro',
  'Polvo espesante sin sabor para liquidos, indicado en disfagia. Envase de 300 g.',
  'nutrition', 15990, 'Farmacias del Sur', 'published', now());

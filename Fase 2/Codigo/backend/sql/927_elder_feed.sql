-- AgeCare — Contenido del adulto mayor
-- 927_elder_feed.sql — Las tarjetas del feed "Para ti"
--
-- EL PROBLEMA
--   La pantalla "Para ti" muestra tarjetas grandes de texto con un boton
--   Escuchar que las lee en voz alta: noticias, chistes, recuerdos,
--   ejercicios suaves y consejos. Pide title, body y una imagen opcional.
--
--   content_items no sirve para eso. Es el catalogo de medios que se
--   reproducen -- musica, radio, audiolibros, juegos, rutinas -- y por eso
--   tiene media_type, duracion y un archivo o una URL externa obligatorios.
--   No tiene cuerpo de texto, que es justamente lo unico que el feed muestra,
--   y sus categorias son otras: de las cinco que ofrece la pantalla solo
--   coincide 'exercise', y aun ahi significa cosas distintas, una rutina en
--   video contra un parrafo que se lee.
--
--   Meter las dos cosas en content_items obligaria a hacer nullable el
--   archivo, agregar un cuerpo de texto que la mitad de las filas nunca usa y
--   duplicar la lista de categorias. La tabla pasaria a significar dos cosas
--   y ningun CHECK podria decir cual de las dos es cada fila.
--
-- LA CORRECCION
--   Tabla propia. El feed es texto para leer, el catalogo es medios para
--   reproducir, y cada uno con sus reglas.

CREATE TABLE elder_feed_items (
    id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),

    type         varchar(12)  NOT NULL,
    title        varchar(150) NOT NULL,
    body         text         NOT NULL,

    image_file_id uuid,
    image_scope   varchar(12),

    -- Para las noticias, de donde salio. No se inventa una fuente: si no
    -- se sabe, queda en NULL y la pantalla no la muestra.
    source       varchar(120),

    status       varchar(12)  NOT NULL DEFAULT 'draft',
    published_at timestamptz,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    deleted_at   timestamptz,

    -- La imagen es del catalogo comun, no del expediente de nadie. La clave
    -- compuesta contra files(id, scope) lo garantiza en el motor.
    CONSTRAINT fk_elder_feed_items_image
        FOREIGN KEY (image_file_id, image_scope)
        REFERENCES files(id, scope) ON DELETE RESTRICT,
    CONSTRAINT ck_elder_feed_items_image_scope CHECK (
        (image_file_id IS NULL AND image_scope IS NULL)
     OR (image_file_id IS NOT NULL AND image_scope = 'catalog')
    ),

    -- Los cinco tipos que la pantalla sabe dibujar, con su icono y color.
    CONSTRAINT ck_elder_feed_items_type CHECK (
        type IN ('news', 'joke', 'memory', 'exercise', 'tip')
    ),
    CONSTRAINT ck_elder_feed_items_title CHECK (btrim(title) <> ''),
    CONSTRAINT ck_elder_feed_items_body  CHECK (btrim(body) <> ''),

    CONSTRAINT ck_elder_feed_items_status CHECK (
        status IN ('draft', 'published', 'archived')
    ),
    CONSTRAINT ck_elder_feed_items_status_fecha CHECK (
        (status = 'draft'  AND published_at IS NULL)
     OR (status <> 'draft' AND published_at IS NOT NULL)
    ),
    -- Solo las noticias llevan fuente.
    CONSTRAINT ck_elder_feed_items_source CHECK (
        source IS NULL OR type = 'news'
    )
);

CREATE INDEX ix_elder_feed_items_publicado
    ON elder_feed_items (type, published_at DESC)
    WHERE status = 'published' AND deleted_at IS NULL;

CREATE TRIGGER tg_elder_feed_items_updated_at
    BEFORE UPDATE ON elder_feed_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE elder_feed_items IS
    'Tarjetas de texto del feed Para ti del adulto mayor. Es texto para leer en voz alta, distinto de content_items, que es el catalogo de medios para reproducir.';
COMMENT ON COLUMN elder_feed_items.body IS
    'Cuerpo de la tarjeta. La pantalla lo lee en voz alta junto con el titulo, asi que se escribe en frases cortas y sin abreviaturas.';

INSERT INTO elder_feed_items (type, title, body, source, status, published_at) VALUES
 ('tip', 'Tomar agua durante el dia',
  'El cuerpo pierde la sensacion de sed con los anios. Deje un vaso con agua a la vista y tome un poco cada vez que pase cerca. Seis a ocho vasos al dia es lo recomendado.',
  NULL, 'published', now()),
 ('tip', 'Levantarse despacio de la cama',
  'Al despertar, quedese sentado al borde de la cama contando hasta diez antes de pararse. Asi la presion se acomoda y se evitan los mareos.',
  NULL, 'published', now()),
 ('exercise', 'Ejercicio de tobillos, sentado',
  'Sentado en una silla firme, estire una pierna y dibuje circulos con el pie, diez hacia un lado y diez hacia el otro. Cambie de pierna. Ayuda a la circulacion y se puede hacer viendo television.',
  NULL, 'published', now()),
 ('exercise', 'Levantarse de la silla, cinco veces',
  'Sin apoyar las manos, parese y sientese cinco veces seguidas, despacio. Si cuesta, use los brazos. Es el mejor ejercicio para mantener la fuerza de las piernas.',
  NULL, 'published', now()),
 ('joke', 'El doctor y la memoria',
  'Le dice el paciente al doctor: doctor, se me olvida todo. Y el doctor le pregunta: desde cuando? Y el paciente responde: desde cuando que?',
  NULL, 'published', now()),
 ('joke', 'Dos amigos en la plaza',
  'Dos amigos conversan en la plaza. Uno dice: mi nieto me enseno a usar el telefono. El otro responde: que bueno. Y el primero: si, ahora me llama para preguntarme como se usa.',
  NULL, 'published', now()),
 ('memory', 'La radio en la cocina',
  'Antes la radio no se apagaba nunca. Sonaba mientras se cocinaba, mientras se planchaba, y toda la casa seguia el mismo programa. Que radio escuchaba usted en su casa?',
  NULL, 'published', now()),
 ('memory', 'Las once de la tarde',
  'El pan amasado recien salido, la mantequilla, el te cargado. Las once no eran solo comida, eran la hora en que la familia se sentaba junta. Con quien tomaba once usted?',
  NULL, 'published', now()),
 ('news', 'Vacunacion contra la influenza',
  'Cada otono el sistema de salud vacuna gratis contra la influenza a las personas mayores de 65 anios. Se aplica en cualquier consultorio, sin hora y presentando la cedula.',
  'Ministerio de Salud', 'published', now()),
 ('news', 'Tarifa rebajada en el transporte',
  'Las personas mayores de 65 anios pueden acceder a tarifa rebajada en el transporte publico tramitando su tarjeta en los puntos de atencion habilitados.',
  'Ministerio de Transportes', 'published', now());

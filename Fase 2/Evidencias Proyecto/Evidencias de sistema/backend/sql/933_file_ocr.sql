-- AgeCare — Texto extraido de los archivos
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--   Una foto de una receta o de un examen es, para la aplicacion, un monton
--   de bytes. Nadie puede buscar dentro, el asistente no la puede citar
--   cuando responde, y el formulario de medicamentos hay que llenarlo
--   mirando la imagen y escribiendo a mano.
--
-- POR QUE UNA TABLA Y NO UNA COLUMNA EN files
--   El texto de un documento de varias paginas son kilobytes, y files se
--   consulta en cada listado de galeria, de documentos y de chat. Ponerlo
--   adentro haria que todas esas consultas arrastren el texto completo sin
--   necesitarlo.
--   Ademas el texto tiene datos propios que no son del archivo: con que
--   motor se extrajo, en que idioma y cuando. El dia que se cambie de motor
--   hay que poder distinguir lo viejo de lo nuevo.
--
-- UNA FILA POR ARCHIVO
--   file_id es la llave primaria, no solo una referencia. Extraer dos veces
--   el mismo archivo no crea dos textos: reemplaza el anterior.

CREATE TABLE IF NOT EXISTS file_ocr (
    file_id      uuid         PRIMARY KEY,
    texto        text         NOT NULL,

    -- Con que se extrajo. Al cambiar de motor, esto dice que filas conviene
    -- volver a procesar y cuales ya estan con el nuevo.
    motor        varchar(40)  NOT NULL,
    idioma       varchar(10)  NOT NULL DEFAULT 'spa',

    -- Confianza media que reporta el motor, de 0 a 100. Queda nula cuando el
    -- motor no la entrega, que es distinto de que sea cero.
    confianza    numeric(5,2),

    -- Cuantos caracteres salieron. Sirve para detectar de un vistazo las
    -- extracciones que no sacaron nada util, que con una foto borrosa o un
    -- manuscrito es lo normal.
    caracteres   int          NOT NULL,

    extraido_at  timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_file_ocr_file
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE RESTRICT,

    CONSTRAINT ck_file_ocr_confianza
        CHECK (confianza IS NULL OR confianza BETWEEN 0 AND 100),
    CONSTRAINT ck_file_ocr_caracteres
        CHECK (caracteres >= 0)
);

COMMENT ON TABLE file_ocr IS
    'Texto extraido de un archivo por OCR. Una fila por archivo; reextraer '
    'reemplaza. Alimenta la busqueda y el contexto del asistente.';
COMMENT ON COLUMN file_ocr.confianza IS
    'Confianza media del motor (0 a 100). Nula si el motor no la reporta.';

-- Para buscar dentro de los documentos de un paciente. El indice es sobre la
-- version normalizada en castellano, asi que "inyeccion" encuentra
-- "Inyección" y al reves.
CREATE INDEX IF NOT EXISTS ix_file_ocr_busqueda
    ON file_ocr USING gin (to_tsvector('spanish', texto));

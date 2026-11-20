-- MIGRACION IDEMPOTENTE
-- Al purgar un archivo se borra tambien su texto OCR (privacidad, RF-43).
--
-- EL PROBLEMA
--   file_ocr guarda el texto extraido de un archivo: el contenido de una receta
--   o de un examen en claro. Purgar un archivo (files.purged_at) borra el
--   binario del almacenamiento y conserva la fila de files como registro, PERO
--   el texto en file_ocr quedaba intacto. O sea, se "eliminaba" la foto de la
--   receta y el texto con los mismos datos sensibles seguia buscable y citable
--   por el asistente. La depuracion quedaba a medias.
--
-- EL ARREGLO
--   Un trigger en files: cuando purged_at pasa de NULL a tener valor (el momento
--   exacto en que se purga el binario, lo dice el propio 510), borra la fila de
--   file_ocr de ese archivo. Queda garantizado a nivel de base, sin depender de
--   que cada camino de codigo se acuerde de hacerlo. Ademas se limpia de una vez
--   el texto de los archivos que ya estaban purgados.
--
--   Idempotente: CREATE OR REPLACE para la funcion, DROP TRIGGER IF EXISTS antes
--   de crear el trigger, y el backfill no encuentra nada en una segunda corrida.

-- 1. Limpiar lo ya purgado: texto OCR de archivos que hoy estan purgados.
DELETE FROM file_ocr fo
 USING files f
 WHERE f.id = fo.file_id
   AND f.purged_at IS NOT NULL;

-- 2. Funcion del trigger: borra el texto OCR del archivo recien purgado.
CREATE OR REPLACE FUNCTION fn_purga_texto_ocr() RETURNS trigger AS $$
BEGIN
    DELETE FROM file_ocr WHERE file_id = NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Dispara solo en la transicion a purgado (purged_at de NULL a no NULL), no
--    en cada update del archivo.
DROP TRIGGER IF EXISTS tg_files_purga_ocr ON files;
CREATE TRIGGER tg_files_purga_ocr
    AFTER UPDATE OF purged_at ON files
    FOR EACH ROW
    WHEN (OLD.purged_at IS NULL AND NEW.purged_at IS NOT NULL)
    EXECUTE FUNCTION fn_purga_texto_ocr();

COMMENT ON FUNCTION fn_purga_texto_ocr() IS
    'Borra el texto OCR (file_ocr) de un archivo cuando se purga su binario. Asi la depuracion del archivo no deja atras el contenido sensible extraido (RF-43).';

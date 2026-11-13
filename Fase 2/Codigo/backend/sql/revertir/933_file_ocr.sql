-- Revierte 933_file_ocr.sql
--
-- PIERDE DATOS: se borra el texto extraido de todos los archivos. Volver a
-- extraerlo es posible, pero hay que pasar cada archivo por el OCR de nuevo.

DROP INDEX IF EXISTS ix_file_ocr_busqueda;
DROP TABLE IF EXISTS file_ocr;

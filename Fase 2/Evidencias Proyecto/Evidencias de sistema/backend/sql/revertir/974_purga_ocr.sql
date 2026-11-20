-- Revierte 974_purga_ocr.sql.
--
-- Quita el trigger que borra el texto OCR al purgar un archivo y su funcion.
-- Despues de esto, purgar un archivo vuelve a dejar su file_ocr intacto (el
-- comportamiento viejo).
--
-- El texto OCR que 974 ya borro de archivos purgados NO se puede recuperar:
-- era justamente lo que habia que eliminar. Revertir solo deja de borrarlo
-- hacia adelante.

DROP TRIGGER IF EXISTS tg_files_purga_ocr ON files;
DROP FUNCTION IF EXISTS fn_purga_texto_ocr();

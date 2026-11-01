-- AgeCare — Ajuste de compatibilidad
-- 923_documentos_identificacion.sql — La categoria de documentos de identidad
--
-- La pantalla de documentos ofrece cuatro categorias al subir: receta, estudio
-- de laboratorio, identificacion y otro. Las tres primeras agrupan el
-- expediente en la lista, cada una con su icono y su titulo.
--
-- ck_medical_documents_category cubre receta y estudio, pero no tiene donde
-- poner una identificacion: la cedula, la credencial de salud, el carnet de
-- discapacidad. Son los documentos que la familia sube primero, porque son los
-- que piden en cada atencion.
--
-- Guardarlos como 'other' no es solo perder la etiqueta. La pantalla agrupa
-- por categoria, asi que las identificaciones caerian mezcladas con todo lo
-- demas en el grupo 'Otros', que es justo lo contrario de lo que esa pantalla
-- intenta hacer.
--
-- 'insurance' tampoco sirve. Es el documento del seguro, no el que identifica
-- a la persona.

ALTER TABLE medical_documents DROP CONSTRAINT IF EXISTS ck_medical_documents_category;

ALTER TABLE medical_documents ADD CONSTRAINT ck_medical_documents_category CHECK (
    category IN ('prescription', 'lab_result', 'imaging', 'report',
                 'discharge', 'consent', 'insurance', 'identification',
                 'other')
);

-- La pantalla pide el expediente de un paciente ordenado por fecha, sin los
-- borrados. El indice sigue esa consulta.
CREATE INDEX IF NOT EXISTS ix_medical_documents_patient_fecha
    ON medical_documents (patient_id, created_at DESC)
    WHERE deleted_at IS NULL;

COMMENT ON COLUMN medical_documents.category IS
    'Tipo de documento, lista cerrada. identification cubre los documentos que identifican a la persona, como la cedula o la credencial de salud, que son distintos de insurance, que es el documento del seguro.';

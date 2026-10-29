-- AgeCare — Corrección estructural
-- 913_files_general.sql — files deja de ser exclusivo del expediente
--
-- EL PROBLEMA
--   files.patient_id era NOT NULL porque files nació como "los archivos del
--   expediente de un paciente". Pero el modelo creció y aparecieron binarios
--   que NO pertenecen a ningún paciente:
--     · content_items (bloque 8), el catálogo de contenido es compartido por
--       toda la plataforma. Su file_id apunta a files, así que hoy habría que
--       colgar un cuento del expediente de alguien al azar.
--     · caregiver_certifications (bloque 9), el certificado es de la cuidadora.
--       Lo esquivé guardando storage_key, mime_type y size_bytes directo en esa
--       tabla, que dejó DOS mecanismos de almacenamiento conviviendo.
--
-- LA CORRECCIÓN
--   files pasa a ser la tabla de binarios de todo el sistema, con un ámbito que
--   dice de quién es cada archivo. patient_id se vuelve opcional y un CHECK
--   obliga a que esté presente exactamente cuando el ámbito es 'patient'.
--
--   Y caregiver_certifications se migra a usar files, para que quede un solo
--   mecanismo y no dos.

-- ─────────────────────────── 1. files general ────────────────────────────────
ALTER TABLE files ALTER COLUMN patient_id DROP NOT NULL;

ALTER TABLE files ADD COLUMN IF NOT EXISTS scope varchar(12) NOT NULL DEFAULT 'patient';

ALTER TABLE files DROP CONSTRAINT IF EXISTS ck_files_scope;
ALTER TABLE files ADD CONSTRAINT ck_files_scope
    CHECK (scope IN ('patient','catalog','caregiver'));

-- El paciente va exactamente cuando el archivo es del expediente. Ni antes ni
-- después: así un archivo de catálogo no puede quedar colgado de una persona.
ALTER TABLE files DROP CONSTRAINT IF EXISTS ck_files_scope_patient;
ALTER TABLE files ADD CONSTRAINT ck_files_scope_patient
    CHECK ((scope = 'patient') = (patient_id IS NOT NULL));

-- Permite amarrar con clave foránea compuesta que un archivo sea del ámbito
-- correcto para quien lo referencia.
ALTER TABLE files DROP CONSTRAINT IF EXISTS uq_files_id_scope;
ALTER TABLE files ADD CONSTRAINT uq_files_id_scope UNIQUE (id, scope);

COMMENT ON COLUMN files.patient_id IS
    'Paciente dueño del archivo. Nulo cuando el archivo no pertenece a un expediente, por ejemplo el catálogo de contenido o el certificado de una cuidadora.';
COMMENT ON COLUMN files.scope IS
    'De quién es el archivo: patient (expediente), catalog (compartido por la plataforma) o caregiver (documentación de una cuidadora).';
COMMENT ON TABLE files IS
    'Archivos binarios de todo el sistema. La BD guarda metadatos y la ruta opaca del almacenamiento, nunca el contenido. El ámbito distingue los del expediente de los compartidos. RF-39, RF-42.';

-- ───────────────── 2. content_items apunta a archivos de catálogo ────────────
ALTER TABLE content_items ADD COLUMN IF NOT EXISTS file_scope varchar(12);

UPDATE content_items SET file_scope = 'catalog' WHERE file_id IS NOT NULL AND file_scope IS NULL;

ALTER TABLE content_items DROP CONSTRAINT IF EXISTS ck_content_items_file_scope;
ALTER TABLE content_items ADD CONSTRAINT ck_content_items_file_scope
    CHECK ((file_id IS NULL AND file_scope IS NULL)
        OR (file_id IS NOT NULL AND file_scope = 'catalog'));

-- Quita la FK simple y la reemplaza por la compuesta, que además del archivo
-- verifica su ámbito. Un ítem del catálogo ya no puede apuntar al archivo de
-- un paciente.
ALTER TABLE content_items DROP CONSTRAINT IF EXISTS content_items_file_id_fkey;
ALTER TABLE content_items DROP CONSTRAINT IF EXISTS fk_content_items_file;
ALTER TABLE content_items ADD CONSTRAINT fk_content_items_file
    FOREIGN KEY (file_id, file_scope) REFERENCES files(id, scope) ON DELETE RESTRICT;

COMMENT ON COLUMN content_items.file_scope IS
    'Siempre catalog. Existe para que la clave foránea compuesta impida que un ítem del catálogo apunte al archivo de un paciente.';

-- ──────────── 3. caregiver_certifications pasa a usar files ──────────────────
ALTER TABLE caregiver_certifications ADD COLUMN IF NOT EXISTS file_id uuid;
ALTER TABLE caregiver_certifications ADD COLUMN IF NOT EXISTS file_scope varchar(12);

-- Mueve a files lo que estuviera guardado en línea.
INSERT INTO files (patient_id, uploaded_by, storage_key, original_name, mime_type,
                   size_bytes, status, upload_expires_at, stored_at, scope)
SELECT NULL, cp.user_id, cc.storage_key, cc.name, cc.mime_type, cc.size_bytes,
       'stored', cc.created_at + interval '15 minutes', cc.created_at, 'caregiver'
  FROM caregiver_certifications cc
  JOIN caregiver_profiles cp ON cp.id = cc.profile_id
 WHERE cc.storage_key IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM files f WHERE f.storage_key = cc.storage_key);

UPDATE caregiver_certifications cc
   SET file_id = f.id, file_scope = 'caregiver'
  FROM files f
 WHERE f.storage_key = cc.storage_key
   AND cc.file_id IS NULL;

-- Fuera el mecanismo duplicado.
ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS ck_caregiver_certifications_archivo;
ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS ck_caregiver_certifications_mime;
ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS ck_caregiver_certifications_size;
ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS ck_caregiver_certifications_verificado_con_archivo;
ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS uq_caregiver_certifications_storage;
ALTER TABLE caregiver_certifications DROP COLUMN IF EXISTS storage_key;
ALTER TABLE caregiver_certifications DROP COLUMN IF EXISTS mime_type;
ALTER TABLE caregiver_certifications DROP COLUMN IF EXISTS size_bytes;

ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS ck_caregiver_certifications_file_scope;
ALTER TABLE caregiver_certifications ADD CONSTRAINT ck_caregiver_certifications_file_scope
    CHECK ((file_id IS NULL AND file_scope IS NULL)
        OR (file_id IS NOT NULL AND file_scope = 'caregiver'));

ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS fk_caregiver_certifications_file;
ALTER TABLE caregiver_certifications ADD CONSTRAINT fk_caregiver_certifications_file
    FOREIGN KEY (file_id, file_scope) REFERENCES files(id, scope) ON DELETE RESTRICT;

ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS uq_caregiver_certifications_file;
ALTER TABLE caregiver_certifications ADD CONSTRAINT uq_caregiver_certifications_file UNIQUE (file_id);

-- No se da por verificado un certificado sin documento que respalde.
ALTER TABLE caregiver_certifications DROP CONSTRAINT IF EXISTS ck_caregiver_certifications_verificado;
ALTER TABLE caregiver_certifications ADD CONSTRAINT ck_caregiver_certifications_verificado
    CHECK (verified_at IS NULL OR file_id IS NOT NULL);

COMMENT ON COLUMN caregiver_certifications.file_id IS
    'Documento de respaldo, en la tabla files con ámbito caregiver. Reemplaza las columnas de almacenamiento que esta tabla guardaba en línea.';
COMMENT ON COLUMN caregiver_certifications.file_scope IS
    'Siempre caregiver. Sostiene la clave foránea compuesta que impide respaldar un certificado con el archivo de un paciente.';

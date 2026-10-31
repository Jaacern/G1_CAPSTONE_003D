-- AgeCare — Ajuste de compatibilidad
-- 919_files_user_scope.sql — Un ambito para los archivos que son de la persona
--
-- EL PROBLEMA
--   files.scope aceptaba tres ambitos: patient, catalog y caregiver. Ninguno
--   sirve para la foto de perfil de un usuario.
--
--   La pantalla de perfil (features/profile/presentation/profile_screen.dart)
--   ya tiene el selector de foto y la sube como kind 'photo', que es el mismo
--   que usan las fotos del expediente de un paciente. El resultado seria que
--   cambiar la foto de perfil exigiria indicar un paciente, y la foto quedaria
--   archivada dentro del expediente clinico de otra persona.
--
--   No es un detalle de prolijidad. Esos archivos tienen reglas de acceso
--   distintas: el expediente lo ve solo el circulo del paciente, y la foto de
--   perfil la tiene que ver cualquiera que comparta un circulo con esa
--   persona, para reconocerla en el chat y en la lista de miembros.
--
-- LA CORRECCION
--   Se agrega el ambito user. El dueno del archivo es uploaded_by, que ya
--   existe y ya es obligatorio, asi que no hace falta ninguna columna nueva.
--
--   ck_files_scope_patient no se toca: dice que patient_id esta presente si y
--   solo si el ambito es patient, y eso sigue siendo cierto. Un archivo de
--   ambito user no pertenece a ningun paciente.

ALTER TABLE files DROP CONSTRAINT IF EXISTS ck_files_scope;

ALTER TABLE files ADD CONSTRAINT ck_files_scope
    CHECK (scope IN ('patient', 'catalog', 'caregiver', 'user'));

-- Los archivos propios de una persona se buscan por su dueno, no por paciente.
CREATE INDEX IF NOT EXISTS ix_files_user_scope
    ON files (uploaded_by)
    WHERE scope = 'user';

COMMENT ON COLUMN files.scope IS
    'De quien es el archivo. patient: del expediente de un paciente, lo ve su circulo. catalog: contenido comun de la aplicacion. caregiver: certificados que la cuidadora publica en el marketplace. user: archivos de la persona misma, como su foto de perfil, visibles para quienes comparten un circulo con ella.';

-- Corrige la atribucion falsa del prescriptor de un tratamiento (hallazgo 2).
--
-- EL PROBLEMA
--   960_migrate_treatments.sql, al migrar el plan viejo de medicamentos, crea
--   un "tratamiento de arranque". Si ningun medicamento tenia prescriptor usa
--   al FAMILIAR owner como prescribed_by, pero igual inserta
--   prescriber_role='doctor'. Queda un familiar registrado como medico, lo que
--   contradice la regla del propio 306 ("SOLO el medico define tratamiento").
--
-- EL ARREGLO
--   El rol del prescriptor solo admitia 'doctor' y 'caregiver', asi que un
--   familiar no tenia un valor honesto. Se agrega 'family' a la lista y se
--   corrige cada tratamiento mal atribuido, poniendo el rol REAL del
--   prescriptor segun su membresia en el paciente.
--
--   Esta migracion corre despues de 960, asi que tambien corrige el caso en un
--   despliegue nuevo: 960 crea el tratamiento con 'doctor' y aqui se arregla.

-- 1. Permitir 'family' como rol del prescriptor.
ALTER TABLE treatments DROP CONSTRAINT IF EXISTS ck_treatments_role;
ALTER TABLE treatments
    ADD CONSTRAINT ck_treatments_role
        CHECK (prescriber_role IN ('doctor', 'caregiver', 'family'));

-- 2. Poner el rol real donde 960 dejo 'doctor' sin serlo.
UPDATE treatments t
   SET prescriber_role = pm.role
  FROM patient_members pm
 WHERE pm.patient_id = t.patient_id
   AND pm.user_id    = t.prescribed_by
   AND pm.removed_at IS NULL
   AND t.prescriber_role = 'doctor'
   AND pm.role IN ('family', 'caregiver');

COMMENT ON COLUMN treatments.prescriber_role IS
    'Rol de quien definio el tratamiento: doctor | caregiver | family. family solo en los tratamientos de arranque migrados del plan de medicamentos viejo, cuando no habia un medico que lo prescribiera (960).';

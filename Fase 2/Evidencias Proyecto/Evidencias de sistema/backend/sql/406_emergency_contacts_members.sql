-- AgeCare — Bloque 4: Alertas y SOS
-- 406_emergency_contacts_members.sql — Contactos de emergencia del grupo + rotación (Fase 6)
--
-- POR QUÉ (decisión del usuario, docs/DECISIONES_ABIERTAS_FICHA.md punto 1)
--   Los contactos de emergencia se ELIGEN del grupo familiar (no se escriben
--   libres) y son ROTATIVOS: quien está disponible se activa; quien ya no puede
--   (ej. pasa a trabajo presencial) se desactiva, y se activa otro (la hermana).
--
--   NO hay prioridad/orden entre contactos: en un SOS se avisa a TODOS por igual,
--   no en cascada. La lista existe para que un médico de urgencias o paramédico
--   sepa a quién llamar (dato de la ficha clínica), no para escalar avisos.
--
--   Cambios sobre emergency_contacts (404):
--     · member_user_id: FK al usuario del grupo que ES este contacto. El nombre y
--       el teléfono salen de su perfil (una sola fuente de verdad; no se duplican).
--     · is_active: estado de la rotación. Un contacto inactivo conserva su fila
--       (historial / se puede reactivar) pero no cuenta como contacto vigente.
--     · first_name/last_name/phone pasan a ser opcionales: si hay member_user_id,
--       los datos vienen del miembro. Se mantienen para contactos libres futuros
--       (un vecino sin cuenta), que hoy no se usan pero el modelo no los prohíbe.
--
--   Correcciones de normalización (criterio de los compañeros):
--     · member_user_id con FK a users(id): el contacto referencia a la persona,
--       no copia sus datos (evita redundancia → 3FN). full_name/phone propios solo
--       aplican al caso de contacto libre sin cuenta.

-- Vínculo al miembro del grupo que es este contacto de emergencia.
ALTER TABLE emergency_contacts
    ADD COLUMN IF NOT EXISTS member_user_id uuid,
    ADD COLUMN IF NOT EXISTS is_active      boolean NOT NULL DEFAULT true;

ALTER TABLE emergency_contacts
    DROP CONSTRAINT IF EXISTS fk_emergency_contacts_member;
ALTER TABLE emergency_contacts
    ADD CONSTRAINT fk_emergency_contacts_member
        FOREIGN KEY (member_user_id) REFERENCES users(id) ON DELETE RESTRICT;

-- first_name/last_name/phone dejan de ser obligatorios: si el contacto es un
-- miembro, sus datos salen del perfil del miembro. Para contacto libre siguen
-- disponibles. (Los CHECK de char_length se vuelven condicionales a NOT NULL.)
ALTER TABLE emergency_contacts ALTER COLUMN first_name DROP NOT NULL;
ALTER TABLE emergency_contacts ALTER COLUMN last_name  DROP NOT NULL;
ALTER TABLE emergency_contacts ALTER COLUMN phone      DROP NOT NULL;

ALTER TABLE emergency_contacts DROP CONSTRAINT IF EXISTS ck_emergency_contacts_first_name;
ALTER TABLE emergency_contacts DROP CONSTRAINT IF EXISTS ck_emergency_contacts_last_name;
ALTER TABLE emergency_contacts DROP CONSTRAINT IF EXISTS ck_emergency_contacts_phone;

ALTER TABLE emergency_contacts ADD CONSTRAINT ck_emergency_contacts_first_name
    CHECK (first_name IS NULL OR char_length(first_name) >= 1);
ALTER TABLE emergency_contacts ADD CONSTRAINT ck_emergency_contacts_last_name
    CHECK (last_name IS NULL OR char_length(last_name) >= 1);
ALTER TABLE emergency_contacts ADD CONSTRAINT ck_emergency_contacts_phone
    CHECK (phone IS NULL OR phone ~ '^\+[0-9]{8,15}$');

-- Un contacto debe ser un miembro O tener datos libres (nombre+teléfono).
ALTER TABLE emergency_contacts DROP CONSTRAINT IF EXISTS ck_emergency_contacts_origen;
ALTER TABLE emergency_contacts ADD CONSTRAINT ck_emergency_contacts_origen
    CHECK (member_user_id IS NOT NULL OR (first_name IS NOT NULL AND phone IS NOT NULL));

-- SIN prioridad/orden entre contactos (decisión del usuario): en un SOS se avisa
-- a TODOS por igual, no en cascada. Los contactos de emergencia son una LISTA de
-- personas que un médico de urgencias o paramédico puede llamar; no hay "primero
-- este, luego el otro". Por eso se retira el índice único por escalation_order.
-- La columna escalation_order queda en la tabla (viene de 404) pero la app no la
-- usa como prioridad. El antiguo índice de unicidad por orden se elimina.
DROP INDEX IF EXISTS ux_emergency_contacts_order;

-- Un mismo miembro no puede estar dos veces como contacto vigente del paciente.
CREATE UNIQUE INDEX IF NOT EXISTS ux_emergency_contacts_member
    ON emergency_contacts (patient_id, member_user_id)
    WHERE deleted_at IS NULL AND member_user_id IS NOT NULL;

COMMENT ON COLUMN emergency_contacts.member_user_id IS
    'Miembro del grupo (users.id) que es este contacto. Nombre y teléfono salen de su perfil. NULL solo para contacto libre sin cuenta (no usado aún).';
COMMENT ON COLUMN emergency_contacts.is_active IS
    'Estado de la rotación: true = contacto vigente ahora. Se desactiva (no se borra) cuando la persona deja de estar disponible; se puede reactivar.';

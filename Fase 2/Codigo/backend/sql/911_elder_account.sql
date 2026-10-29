-- AgeCare — Bloque 6: Auditoría y administración
-- 911_elder_account.sql — Cierre de la cuenta del adulto mayor
--
-- LA DECISIÓN QUE SE ESTABA ARRASTRANDO
--   El modelo tenía dos ideas en conflicto:
--     · patient_members.role acepta 'elder' y patient_members.user_id es NOT
--       NULL, o sea el adulto mayor SÍ tiene cuenta.
--     · elder_devices se diseñó sobre la idea de que la credencial la tiene el
--       dispositivo y el adulto mayor NO tiene cuenta.
--   Mientras eso no se resolviera, el adulto mayor no podía escribir en el chat
--   (messages.sender_id exige users) ni consultar al asistente
--   (assistant_queries.user_id exige users), aunque RF-53 diga "Todos" y
--   RF-63/RF-64 sean funciones suyas.
--
-- CÓMO QUEDA
--   El adulto mayor SÍ tiene fila en users. Es lo que el seed de desarrollo ya
--   venía haciendo (elena@agecare.cl con rol elder), así que esto no cambia el
--   modelo: lo deja explícito y cierra el conflicto.
--
--   La cuenta se crea sola al canjear el código de vinculación (RF-68) y NO es
--   una cuenta con la que alguien inicie sesión:
--     · password_hash lleva el centinela '!' , que no es un hash bcrypt válido
--       y por lo tanto no puede coincidir con ninguna contraseña.
--     · email se genera como elder+<uuid>@agecare.local, un dominio reservado
--       que no recibe correo, para respetar el NOT NULL UNIQUE de users sin
--       inventarle una casilla al adulto mayor.
--   Quien autentica sigue siendo el dispositivo, con elder_devices.session_token_hash.
--   La cuenta existe para poder firmar lo que el adulto mayor hace, no para que
--   inicie sesión.
--
--   Se agrega elder_devices.user_id para dejar escrita esa correspondencia, que
--   hasta ahora solo se podía deducir pasando por patient_members.

ALTER TABLE elder_devices
    ADD COLUMN IF NOT EXISTS user_id uuid;

ALTER TABLE elder_devices
    DROP CONSTRAINT IF EXISTS fk_elder_devices_user;

ALTER TABLE elder_devices
    ADD CONSTRAINT fk_elder_devices_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT;

-- Rellena los dispositivos que ya existan, buscando al miembro con rol elder
-- del mismo paciente. Idempotente.
UPDATE elder_devices ed
   SET user_id = pm.user_id
  FROM patient_members pm
 WHERE pm.patient_id = ed.patient_id
   AND pm.role = 'elder'
   AND pm.removed_at IS NULL
   AND ed.user_id IS NULL;

-- Un dispositivo vinculado y activo tiene que tener a quién representar.
ALTER TABLE elder_devices DROP CONSTRAINT IF EXISTS ck_elder_devices_cuenta;
ALTER TABLE elder_devices
    ADD CONSTRAINT ck_elder_devices_cuenta
        CHECK (unlinked_at IS NOT NULL OR user_id IS NOT NULL) NOT VALID;

CREATE INDEX IF NOT EXISTS ix_elder_devices_user
    ON elder_devices (user_id)
    WHERE unlinked_at IS NULL;

COMMENT ON COLUMN elder_devices.user_id IS
    'Cuenta del adulto mayor que este dispositivo representa. La cuenta no permite inicio de sesión (password_hash centinela y correo en dominio reservado); quien autentica es el dispositivo con session_token_hash. Existe para que el adulto mayor pueda figurar como autor en chat, asistente y reacciones.';

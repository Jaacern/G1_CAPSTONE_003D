-- AgeCare — Administracion
-- 936_admin_usuarios.sql — Desactivar cuentas con trazabilidad y auditar al personal
-- MIGRACION IDEMPOTENTE
--
-- QUE RESUELVE
--     El panel de administracion necesita tres cosas que el modelo no
--     registraba:
--
--     1. Por que, cuando y quien desactivo una cuenta. users.is_active ya
--        existia, pero solo decia "false"; sin motivo ni fecha no se puede
--        ni responder un reclamo ni medir la baja de usuarios.
--
--     2. Quien asigno un plan a mano y por que. Una suscripcion creada por
--        el personal (cortesia, compensacion, correccion) no es lo mismo
--        que una comprada, y mezclarlas ensucia la metrica de conversion.
--
--     3. Un registro de las acciones del personal sobre cuentas. Es una
--        tabla de solo agregar: nada la actualiza ni la borra.
--
-- DESACTIVAR NO ES ELIMINAR
--     deleted_at sigue siendo la baja que pide el propio usuario (requisito
--     de Google Play). deactivated_at es la decision de soporte. Se
--     mantienen separadas porque una cuenta desactivada por soporte se
--     puede reactivar y una eliminada por su titular no.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS deactivated_at     timestamptz,
    ADD COLUMN IF NOT EXISTS deactivated_reason varchar(200),
    ADD COLUMN IF NOT EXISTS deactivated_by     uuid;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_users_deactivated_by') THEN
        ALTER TABLE users
            ADD CONSTRAINT fk_users_deactivated_by
            FOREIGN KEY (deactivated_by) REFERENCES users(id) ON DELETE RESTRICT;
    END IF;
END $$;

COMMENT ON COLUMN users.deactivated_at IS
    'Cuando el personal desactivo la cuenta. NULL = no esta desactivada. Distinto de deleted_at, que es la baja pedida por el propio usuario.';
COMMENT ON COLUMN users.deactivated_reason IS
    'Motivo de la desactivacion, escrito por el personal.';
COMMENT ON COLUMN users.deactivated_by IS
    'Miembro del personal que la desactivo.';

-- Altas y bajas por mes salen de aqui sin recorrer toda la tabla.
CREATE INDEX IF NOT EXISTS ix_users_desactivados
    ON users (deactivated_at) WHERE deactivated_at IS NOT NULL;

-- Plan asignado a mano.
ALTER TABLE subscriptions
    ADD COLUMN IF NOT EXISTS granted_by    uuid,
    ADD COLUMN IF NOT EXISTS change_reason varchar(200);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_subscriptions_granted_by') THEN
        ALTER TABLE subscriptions
            ADD CONSTRAINT fk_subscriptions_granted_by
            FOREIGN KEY (granted_by) REFERENCES users(id) ON DELETE RESTRICT;
    END IF;
END $$;

COMMENT ON COLUMN subscriptions.granted_by IS
    'Si la suscripcion la creo el personal a mano, quien fue. NULL = nacio de una compra del usuario.';
COMMENT ON COLUMN subscriptions.change_reason IS
    'Motivo del cambio manual de plan (cortesia, correccion, compensacion...).';

-- Registro de acciones del personal sobre cuentas.
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id       uuid        NOT NULL,
    action         varchar(40) NOT NULL,
    target_user_id uuid,
    detail         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_admin_audit_actor
        FOREIGN KEY (actor_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_admin_audit_target
        FOREIGN KEY (target_user_id) REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_admin_audit_fecha
    ON admin_audit_log (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_admin_audit_objetivo
    ON admin_audit_log (target_user_id, created_at DESC);

COMMENT ON TABLE admin_audit_log IS
    'Acciones del personal sobre cuentas de usuario (cambio de plan, desactivacion, reactivacion). Solo se agrega; nada la modifica ni la borra.';
COMMENT ON COLUMN admin_audit_log.action IS
    'plan_assigned | user_deactivated | user_reactivated.';
COMMENT ON COLUMN admin_audit_log.detail IS
    'Datos de la accion: motivo, plan anterior y nuevo, etc.';

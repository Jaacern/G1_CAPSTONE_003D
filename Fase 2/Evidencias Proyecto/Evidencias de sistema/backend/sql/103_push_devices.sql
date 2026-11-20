-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 3 de 6: push_devices

CREATE TABLE push_devices(
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
user_id uuid NOT NULL,
push_token varchar(255) NOT NULL,
platform varchar(10) NOT NULL,
is_active boolean NOT NULL DEFAULT true,
last_seen_at timestamptz NOT NULL DEFAULT now(),
created_at timestamptz  NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_push_devices_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,
CONSTRAINT ck_push_devices_platform
    CHECK (platform IN ('ios', 'android', 'web'))
);

--Unico en toda la tabla no por usuario
--Esto es lo que el telefono cambie de dueño
CREATE UNIQUE INDEX ux_push_devices_token
    ON push_devices (push_token);

--Esto es lo que manda la alerta a los aparatos activos
CREATE INDEX ix_push_devices_user_active
    ON push_devices (user_id) WHERE is_active;

COMMENT ON TABLE  push_devices IS
    'Aparatos registrados para recibir notificaciones push. Sin esto, las alertas no llegan a nadie.';
COMMENT ON COLUMN push_devices.user_id IS
    'Dueño actual del aparato. Puede cambiar si otra persona inicia sesión en el mismo teléfono.';
COMMENT ON COLUMN push_devices.push_token IS
    'Código que entrega FCM o APNs. Identifica la instalación de la app, no a la persona. Único en toda la tabla.';
COMMENT ON COLUMN push_devices.platform IS
    'Sistema del aparato: ios | android | web.';
COMMENT ON COLUMN push_devices.is_active IS
    'false = se cerró sesión en ese aparato o el token dejó de ser válido. Se deja de enviar, pero no se borra.';
COMMENT ON COLUMN push_devices.last_seen_at IS
    'Última vez que la app confirmó este aparato. Sirve para limpiar los abandonados.';
COMMENT ON COLUMN push_devices.created_at IS
    'Primer registro del aparato.';
COMMENT ON COLUMN push_devices.updated_at IS
    'Última modificación. La mantiene el trigger.';


CREATE TRIGGER tg_push_devices_updated_at
    BEFORE UPDATE ON push_devices
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON COLUMN push_devices.updated_at IS
    'Última modificación. Trigger tg_push_devices_updated_at agregado en corrección 2FN: faltaba en la versión original.';

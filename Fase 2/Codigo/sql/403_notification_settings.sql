-- Tabla 3 de 5: notification_settings


CREATE TABLE notification_settings (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
user_id uuid  NOT NULL,
alert_type varchar(20) NOT NULL,
push_enabled boolean NOT NULL DEFAULT true,
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_notification_settings_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT uq_notification_settings_pair
    UNIQUE (user_id, alert_type),
CONSTRAINT ck_notification_settings_type
    CHECK (alert_type IN ('fall','vital_out_of_range','missed_dose','sos','wearable_offline')),
CONSTRAINT ck_notification_settings_critical_locked
    CHECK (push_enabled OR alert_type NOT IN ('fall','sos'))
);

CREATE TRIGGER tg_notification_settings_updated_at
    BEFORE UPDATE ON notification_settings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  notification_settings IS
    'Preferencias de notificación por usuario y tipo de alerta (endpoints 9.4 y 9.5).';
COMMENT ON CONSTRAINT ck_notification_settings_critical_locked ON notification_settings IS
    'Las alertas de caída y SOS no se pueden desactivar (RF-50). La restricción vive en la base, no solo en la interfaz.';

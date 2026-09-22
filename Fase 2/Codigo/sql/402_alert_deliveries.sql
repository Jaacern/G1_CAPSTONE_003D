-- AgeCare — Bloque 4: Alertas y emergencias
-- Tabla 2 de 5: alert_deliveries

CREATE TABLE alert_deliveries (
id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
alert_id uuid NOT NULL,
user_id uuid NOT NULL,
push_device_id uuid,
channel  varchar(10) NOT NULL DEFAULT 'push',
status  varchar(10) NOT NULL DEFAULT 'queued',
sent_at  timestamptz,
delivered_at timestamptz,
opened_at timestamptz,
error_detail varchar(300),
created_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_alert_deliveries_alert
    FOREIGN KEY (alert_id) REFERENCES alerts(id) ON DELETE CASCADE,
CONSTRAINT fk_alert_deliveries_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT fk_alert_deliveries_device
    FOREIGN KEY (push_device_id) REFERENCES push_devices(id) ON DELETE SET NULL,

CONSTRAINT ck_alert_deliveries_channel
    CHECK (channel IN ('push','email','sms','in_app')),
CONSTRAINT ck_alert_deliveries_status
    CHECK (status IN ('queued','sent','delivered','opened','failed')),
CONSTRAINT ck_alert_deliveries_failed
    CHECK (status <> 'failed' OR error_detail IS NOT NULL),
-- La secuencia temporal no puede ir al revés
CONSTRAINT ck_alert_deliveries_order
    CHECK ((delivered_at IS NULL OR sent_at IS NULL OR delivered_at >= sent_at)
    AND (opened_at    IS NULL OR delivered_at IS NULL OR opened_at >= delivered_at))
);

-- Todas las entregas de una alerta (para el detalle y el diagnóstico).
CREATE INDEX ix_alert_deliveries_alert
    ON alert_deliveries (alert_id);

-- Reintentos y diagnóstico de fallas.
CREATE INDEX ix_alert_deliveries_failed
    ON alert_deliveries (created_at) WHERE status = 'failed';

COMMENT ON TABLE  alert_deliveries IS
    'Una fila por cada intento de notificar a una persona sobre una alerta. No está en el Anexo A: se agrega porque sin ella los RNF-04 y RNF-05, que exigen latencias medibles, no se pueden comprobar.';
COMMENT ON COLUMN alert_deliveries.sent_at IS
    'Momento en que el backend entregó la notificación al proveedor de push.';
COMMENT ON COLUMN alert_deliveries.delivered_at IS
    'Momento en que el proveedor confirmó la entrega al aparato. La diferencia con sent_at es la latencia que mide el RNF-05.';
COMMENT ON COLUMN alert_deliveries.opened_at IS
    'Momento en que el usuario abrió la notificación. Distinto de delivered_at: llegar no es lo mismo que enterarse.';
COMMENT ON COLUMN alert_deliveries.channel IS
    'push es el canal principal. Los demás cubren el RF-82: vía alternativa cuando el push no se puede entregar.';

-- AgeCare — Bloque 4: Alertas y emergencias
-- Tabla 1 de 5: alerts

CREATE TABLE alerts (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
type varchar(20) NOT NULL,
severity varchar(10) NOT NULL,
title varchar(120) NOT NULL,
detail text,
payload jsonb,
dedup_key varchar(60),
status varchar(12) NOT NULL DEFAULT 'active',
acknowledged_by uuid,
acknowledged_at timestamptz,
resolved_by uuid,
resolved_at timestamptz,
resolution_note varchar(500),
escalated_at timestamptz,
created_at timestamptz NOT NULL DEFAULT now(),
update_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_alerts_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_alerts_acknowledged_by
    FOREIGN KEY (acknowledged_by) REFERENCES users(id) ON DELETE SET NULL,
CONSTRAINT fk_alerts_resolved_by
    FOREIGN KEY (resolved_by) REFERENCES users(id) ON DELETE SET NULL,

CONSTRAINT ck_alerts_type
    CHECK (type IN ('fall','vital_out_of_range','missed_dose','sos','wearable_offline')),
CONSTRAINT ck_alerts_severity
    CHECK (severity IN ('info','warning','critical')),
CONSTRAINT ck_alerts_status
    CHECK (status IN ('active','acknowledged','resolved')),

-- Atender registra quién y cuándo, siempre juntos
CONSTRAINT ck_alerts_ack_pair
    CHECK ((acknowledged_at IS NULL) = (acknowledged_by IS NULL)),
CONSTRAINT ck_alerts_resolved_pair
    CHECK ((resolved_at IS NULL) = (resolved_by IS NULL)),
-- El estado tiene que ser coherente con las marcas de tiempo
CONSTRAINT ck_alerts_status_ack
    CHECK (status = 'active' OR acknowledged_at IS NOT NULL),
CONSTRAINT ck_alerts_status_resolved
    CHECK (status <> 'resolved' OR resolved_at IS NOT NULL),
-- No se puede resolver antes de atender
CONSTRAINT ck_alerts_order
    CHECK (resolved_at IS NULL OR acknowledged_at IS NULL
        OR resolved_at >= acknowledged_at)
);

-- Centro de alertas: activas primero, más recientes arriba.
CREATE INDEX ix_alerts_patient_status
    ON alerts (patient_id, status, created_at DESC);

-- Deduplicación: buscar la misma condición en los últimos 30 minutos.
CREATE INDEX ix_alerts_dedup
    ON alerts (patient_id, dedup_key, created_at DESC)
    WHERE dedup_key IS NOT NULL;

-- Vigilante de escalamiento: críticas sin atender.
CREATE INDEX ix_alerts_pending_critical
    ON alerts (created_at) WHERE status = 'active' AND severity = 'critical';

CREATE TRIGGER tg_alerts_updated_at
    BEFORE UPDATE ON alerts
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  alerts IS
    'Alertas generadas por el sistema. Pilar central del producto: caída, vital fuera de rango, dosis no administrada, SOS y wearable sin datos.';
COMMENT ON COLUMN alerts.acknowledged_at IS
    'Momento en que alguien atendió la alerta. NO está en el Anexo A: se agrega porque sin ella es imposible medir el tiempo de respuesta que exigen el ticket AGE-508 y el objetivo específico de Fase 1.';
COMMENT ON COLUMN alerts.dedup_key IS
    'Identifica la condición que originó la alerta (ej. spo2_low). Permite no repetir alertas por la misma causa dentro de 30 minutos (RF-46, AGE-501). La ventana de tiempo la evalúa el motor; la base aporta el índice.';
COMMENT ON COLUMN alerts.payload IS
    'Datos que originaron la alerta: la lectura fuera de rango, la dosis omitida, etc. Sin estructura fija porque varía según el tipo.';
COMMENT ON COLUMN alerts.escalated_at IS
    'Momento en que se escaló a los siguientes contactos por falta de atención (RF-52). NULL = no escalada.';

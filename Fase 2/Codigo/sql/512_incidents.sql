-- ============================================================================
-- BLOQUE 5 · Bitacora y archivos
-- 512_incidents.sql — Incidentes del cuidado
-- Requisitos: RF-36 (registrar incidente con tipo, gravedad y hora;
--             genera alerta si es critico)
-- ----------------------------------------------------------------------------
-- Un incidente no es una observacion. La observacion describe el dia; el
-- incidente describe algo que salio mal y que puede escalar. Por eso tiene
-- gravedad, accion tomada y un vinculo opcional a la alerta que genero.
--
-- La parte "genera alerta si es critico" de RF-36 queda impuesta por el motor,
-- no por la aplicacion: ck_incidents_critical_has_alert. Un incidente critico
-- sin alerta asociada no se puede insertar.
-- ============================================================================

CREATE TABLE incidents (
    id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    uuid          NOT NULL,
    reported_by   uuid          NOT NULL,
    type          varchar(20)   NOT NULL,
    severity      varchar(10)   NOT NULL,
    occurred_at   timestamptz   NOT NULL,
    description   varchar(1000) NOT NULL,
    action_taken  varchar(1000),
    alert_id      uuid,
    photo_file_id uuid,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    updated_at    timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT fk_incidents_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_incidents_reported_by
        FOREIGN KEY (reported_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_incidents_alert
        FOREIGN KEY (alert_id) REFERENCES alerts(id) ON DELETE RESTRICT,
    CONSTRAINT fk_incidents_photo
        FOREIGN KEY (photo_file_id) REFERENCES files(id) ON DELETE RESTRICT,

    -- Una alerta pertenece a un solo incidente, igual que en sos_events.
    CONSTRAINT uq_incidents_alert UNIQUE (alert_id),

    CONSTRAINT ck_incidents_type CHECK (
        type IN ('fall','wandering','aggression','refusal','injury',
                 'choking','disorientation','other')
    ),
    CONSTRAINT ck_incidents_severity CHECK (
        severity IN ('low','moderate','high','critical')
    ),
    -- RF-36: si es critico, tiene que existir la alerta. Lo garantiza el motor.
    CONSTRAINT ck_incidents_critical_has_alert CHECK (
        severity <> 'critical' OR alert_id IS NOT NULL
    ),
    CONSTRAINT ck_incidents_description CHECK (btrim(description) <> '')
);

-- Historial de incidentes de un paciente.
CREATE INDEX ix_incidents_patient_occurred
    ON incidents (patient_id, occurred_at DESC);

-- Los graves y criticos son los que se revisan primero.
CREATE INDEX ix_incidents_severe
    ON incidents (patient_id, occurred_at DESC)
    WHERE severity IN ('high','critical');

COMMENT ON TABLE  incidents IS 'Incidentes ocurridos durante el cuidado. Los criticos obligan a tener una alerta asociada. RF-36.';
COMMENT ON COLUMN incidents.id IS 'Identificador del incidente.';
COMMENT ON COLUMN incidents.patient_id IS 'Paciente afectado.';
COMMENT ON COLUMN incidents.reported_by IS 'Usuario que reporto el incidente.';
COMMENT ON COLUMN incidents.type IS 'Tipo de incidente. Lista cerrada.';
COMMENT ON COLUMN incidents.severity IS 'Gravedad: low, moderate, high o critical. Critical obliga a generar alerta.';
COMMENT ON COLUMN incidents.occurred_at IS 'Hora en que ocurrio el incidente (RF-36).';
COMMENT ON COLUMN incidents.description IS 'Relato de lo ocurrido. No puede quedar vacio.';
COMMENT ON COLUMN incidents.action_taken IS 'Que se hizo frente al incidente.';
COMMENT ON COLUMN incidents.alert_id IS 'Alerta generada por el incidente. Obligatoria cuando la gravedad es critical.';
COMMENT ON COLUMN incidents.photo_file_id IS 'Fotografia de respaldo opcional.';
COMMENT ON COLUMN incidents.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN incidents.updated_at IS 'Fecha de la ultima modificacion del registro.';

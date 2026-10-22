-- Tabla 5 de 5: sos_events
CREATE TABLE sos_events (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
triggered_by uuid,
alert_id uuid NOT NULL,
note varchar(300),
latitude numeric(9,6),
longitude numeric(9,6),
created_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_sos_events_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
CONSTRAINT fk_sos_events_user
    FOREIGN KEY (triggered_by) REFERENCES users(id) ON DELETE RESTRICT,
CONSTRAINT fk_sos_events_alert
    FOREIGN KEY (alert_id) REFERENCES alerts(id) ON DELETE RESTRICT,
CONSTRAINT uq_sos_events_alert
    UNIQUE (alert_id),
CONSTRAINT ck_sos_events_coords
    CHECK ((latitude IS NULL) = (longitude IS NULL)),
CONSTRAINT ck_sos_events_lat
    CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
CONSTRAINT ck_sos_events_lng
    CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180)
);

CREATE INDEX ix_sos_events_patient
    ON sos_events (patient_id, created_at DESC);

COMMENT ON TABLE  sos_events IS
    'Activaciones del botón de emergencia. Cada una genera exactamente una alerta crítica (UNIQUE sobre alert_id).';
COMMENT ON COLUMN sos_events.latitude IS
    'Ubicación al momento del SOS. No está en el Anexo A, pero la app la captura: el pubspec.yaml incluye geolocator con el comentario "ubicación para SOS".';
COMMENT ON COLUMN sos_events.triggered_by IS
    'Quién lo activó: cuidadora o el propio adulto mayor (RF-51). ON DELETE RESTRICT: el evento queda en el expediente.';

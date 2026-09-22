--Bloque 2, vitals y wearable
-- Tabla 1 de 3: wearables

CREATE TABLE wearables (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid NOT NULL,
    provider varchar(20) NOT NULL DEFAULT 'simulator',
    serial_number varchar(64) NOT NULL,
    model varchar(60),
    battery_pct smallint,
    last_sync_at timestamptz,
    unlinked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_wearables_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT ck_wearables_provider
    CHECK (provider IN ('simulator','healthkit','health_connect','garmin','whoop')),
CONSTRAINT ck_wearables_battery
    CHECK (battery_pct IS NULL OR battery_pct BETWEEN 0 AND 100),
CONSTRAINT ck_wearables_unlinked
    CHECK (unlinked_at IS NULL OR unlinked_at >= created_at)
);

-- Un solo aparato vigente por paciente.
CREATE UNIQUE INDEX ux_wearables_patient_active
    ON wearables (patient_id) WHERE unlinked_at IS NULL;

-- El mismo aparato no puede estar vinculado a dos pacientes a la vez,
-- pero sí puede reutilizarse si se desvincula.
CREATE UNIQUE INDEX ux_wearables_serial_active
    ON wearables (provider, serial_number) WHERE unlinked_at IS NULL;

-- Para el vigilante que detecta wearables sin datos (Anexo B).
CREATE INDEX ix_wearables_last_sync
    ON wearables (last_sync_at) WHERE unlinked_at IS NULL;

CREATE TRIGGER tg_wearables_updated_at
    BEFORE UPDATE ON wearables
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  wearables IS
    'Dispositivo vestible vinculado a un paciente. Guarda el aparato y su estado; las mediciones viven en vital_readings.';
COMMENT ON COLUMN wearables.provider IS
    'Origen de los datos: simulator (v1 del plan) | healthkit | health_connect | garmin | whoop, vía Spike API.';
COMMENT ON COLUMN wearables.serial_number IS
    'Número de serie del aparato. Único junto al proveedor, y solo entre los vinculados: un reloj desvinculado puede asignarse a otro paciente.';
COMMENT ON COLUMN wearables.battery_pct IS
    'Nivel de batería, 0 a 100. NULL si el aparato aún no ha reportado (RF-16).';
COMMENT ON COLUMN wearables.last_sync_at IS
    'Última medición recibida. Base de la alerta wearable_offline: sin datos por más de 2 horas (Anexo B). NO se guarda un estado "conectado": se calcula comparando con la hora actual.';
COMMENT ON COLUMN wearables.unlinked_at IS
    'Desvinculación. NULL = vigente. Se conserva la fila para mantener el historial de aparatos del paciente.';

-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 2 de 3: vital_readings  (PARTICIONADA POR MES)

-- La tabla madre
CREATE TABLE vital_readings (
id uuid NOT NULL DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
type varchar(16) NOT NULL,
value numeric(8,2) NOT NULL,
value_secondary numeric(8,2),
measured_at timestamptz NOT NULL,
source varchar(10) NOT NULL,
meta jsonb,
created_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT pk_vital_readings
    PRIMARY KEY (id, measured_at),
CONSTRAINT uq_vital_readings_natural
    UNIQUE (patient_id, type, measured_at, source),
CONSTRAINT fk_vital_readings_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT ck_vital_readings_type
    CHECK (type IN ('heart_rate','spo2','sleep','steps','sedentary_min',
                    'fall_event','blood_pressure','temperature','glucose')),
CONSTRAINT ck_vital_readings_source
    CHECK (source IN ('wearable','manual')),
CONSTRAINT ck_vital_readings_secondary
    CHECK (value_secondary IS NULL OR type = 'blood_pressure')
) PARTITION BY RANGE (measured_at);

--  El índice de series y últimos valores.
--   Al crearlo en la madre, cada partición lo hereda automáticamente,
--   incluidas las que se creen en el futuro.
CREATE INDEX ix_vital_readings_series
    ON vital_readings (patient_id, type, measured_at DESC);

--  Mantenimiento automatizado de particiones
CREATE OR REPLACE FUNCTION ensure_vital_readings_partitions(
    months_ahead int DEFAULT 3,
    months_back  int DEFAULT 0
)
RETURNS void AS $$
DECLARE
    m         int;
    base      date := date_trunc('month', now())::date;
    d_from    date;
    d_to      date;
    part_name text;
BEGIN
    FOR m IN -months_back..months_ahead LOOP
        d_from    := base + (m       || ' month')::interval;
        d_to      := base + ((m + 1) || ' month')::interval;
        part_name := format('vital_readings_%s', to_char(d_from, 'YYYY_MM'));

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF vital_readings
            FOR VALUES FROM (%L) TO (%L)',
            part_name,
            d_from::text || ' 00:00:00+00',
            d_to::text   || ' 00:00:00+00'
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ensure_vital_readings_partitions(int, int) IS
    'Crea las particiones mensuales faltantes. En producción el worker la llama cada mes con months_ahead=3. months_back sirve para sembrar datos históricos de demostración.';

-- Doce meses hacia atrás y doce hacia adelante.
--  Cubre todo el proyecto y permite sembrar historia para la analítica.
SELECT ensure_vital_readings_partitions(12, 12);

-- Red de seguridad. Debe permanecer VACÍA:
-- si tiene filas, significa que faltó crear una partición.
CREATE TABLE vital_readings_default PARTITION OF vital_readings DEFAULT;

-- Documentación
COMMENT ON TABLE  vital_readings IS
    'Mediciones de signos vitales. Particionada por mes (RNF-07) por el volumen del dominio: un wearable genera decenas de miles de filas diarias. Tabla append-only: una medición es un hecho ocurrido, no se edita ni se borra.';
COMMENT ON COLUMN vital_readings.id IS
    'Identificador de la lectura. Forma la clave primaria junto a measured_at, porque Postgres exige que la PK de una tabla particionada incluya la columna de particionamiento.';
COMMENT ON COLUMN vital_readings.patient_id IS
    'Paciente al que pertenece la medición.';
COMMENT ON COLUMN vital_readings.type IS
    'Tipo de signo vital, según la enumeración VitalType de la especificación.';
COMMENT ON COLUMN vital_readings.value IS
    'Valor principal. En presión arterial corresponde a la sistólica.';
COMMENT ON COLUMN vital_readings.value_secondary IS
    'Solo para presión arterial: la diastólica. NULL en todos los demás tipos, garantizado por CHECK.';
COMMENT ON COLUMN vital_readings.measured_at IS
    'Momento de la medición. Columna de particionamiento y parte de la clave de idempotencia.';
COMMENT ON COLUMN vital_readings.source IS
    'wearable = automática del dispositivo. manual = registrada por la cuidadora (RF-18).';
COMMENT ON COLUMN vital_readings.meta IS
    'Datos adicionales del proveedor, sin estructura fija.';
COMMENT ON COLUMN vital_readings.created_at IS
    'Momento en que la medición llegó al servidor. Distinto de measured_at, que es cuando ocurrió.';

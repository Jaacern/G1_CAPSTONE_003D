-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 2 de 3: vital_readings  (PARTICIONADA POR MES)
--
-- Correcciones 2FN aplicadas:
--   · CHECK de type eliminado → FK a vital_types.code (catálogo centralizado)
--   · PK compuesta (id, measured_at): excepción técnica documentada.
--     measured_at está en la PK únicamente porque PostgreSQL exige que la columna
--     de particionamiento forme parte de la clave primaria. Los atributos dependen
--     solo de id, no de (id, measured_at). Esto viola 2FN en sentido estricto;
--     se acepta como concesión técnica del motor de particionamiento (RNF-07).

CREATE TABLE vital_readings (
    id              uuid          NOT NULL DEFAULT gen_random_uuid(),
    patient_id      uuid          NOT NULL,
    -- FK a vital_types: fuente única de verdad para tipos válidos
    type            varchar(16)   NOT NULL,
    value           numeric(8,2)  NOT NULL,
    value_secondary numeric(8,2),
    measured_at     timestamptz   NOT NULL,
    source          varchar(10)   NOT NULL,
    meta            jsonb,
    created_at      timestamptz   NOT NULL DEFAULT now(),

    -- EXCEPCIÓN 2FN DOCUMENTADA:
    -- La PK (id, measured_at) es requerida por PostgreSQL para tablas particionadas
    -- por rango (PARTITION BY RANGE). En el modelo relacional puro la PK debería
    -- ser solo id; measured_at se agrega exclusivamente por restricción del motor.
    -- Todos los atributos dependen funcionalmente de id, no de measured_at.
    CONSTRAINT pk_vital_readings
        PRIMARY KEY (id, measured_at),

    CONSTRAINT uq_vital_readings_natural
        UNIQUE (patient_id, type, measured_at, source),

    CONSTRAINT fk_vital_readings_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,

    -- FK al catálogo: reemplaza el CHECK de lista duplicada
    CONSTRAINT fk_vital_readings_type
        FOREIGN KEY (type) REFERENCES vital_types(code),

    CONSTRAINT ck_vital_readings_source
        CHECK (source IN ('wearable','manual')),
    -- value_secondary solo es válido para blood_pressure
    CONSTRAINT ck_vital_readings_secondary
        CHECK (value_secondary IS NULL OR type = 'blood_pressure')

) PARTITION BY RANGE (measured_at);

-- Índice de series y últimos valores. Cada partición lo hereda.
CREATE INDEX ix_vital_readings_series
    ON vital_readings (patient_id, type, measured_at DESC);

-- ─── Mantenimiento automático de particiones ────────────────────
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
    'Crea las particiones mensuales faltantes. En producción el worker la llama cada mes con months_ahead=3.';

SELECT ensure_vital_readings_partitions(12, 12);

-- Red de seguridad: debe permanecer VACÍA.
CREATE TABLE vital_readings_default PARTITION OF vital_readings DEFAULT;

COMMENT ON TABLE  vital_readings IS
    'Mediciones de signos vitales. Particionada por mes (RNF-07). Tabla append-only. PK (id, measured_at): excepción técnica de PostgreSQL para tablas particionadas, documentada en el constraint pk_vital_readings.';
COMMENT ON COLUMN vital_readings.type IS
    'Tipo de signo vital. FK a vital_types.code (catálogo centralizado). Reemplaza el CHECK de lista duplicada.';
COMMENT ON COLUMN vital_readings.value IS
    'Valor principal. En presión arterial: sistólica.';
COMMENT ON COLUMN vital_readings.value_secondary IS
    'Solo para blood_pressure: diastólica. NULL en todos los demás tipos.';
COMMENT ON COLUMN vital_readings.measured_at IS
    'Momento de la medición. Columna de particionamiento. Parte de la PK por requerimiento técnico de PostgreSQL, no por diseño relacional.';
COMMENT ON COLUMN vital_readings.source IS
    'wearable = automática del dispositivo. manual = registrada por la cuidadora (RF-18).';
COMMENT ON COLUMN vital_readings.meta IS
    'Datos adicionales del proveedor del wearable. jsonb INTENCIONAL: cada proveedor (Garmin, Whoop, HealthKit) envía campos distintos y opcionales. No se consulta ni se filtra: solo se conserva como trazabilidad. Excepción documentada a 1FN.';

-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla: wellbeing_snapshots
--
-- Análisis de realidad:
--   El indicador diario de bienestar (semáforo: ok | warning | attention) se
--   calcula a partir de vitals, adherencia y eventos del día. Si solo se calcula
--   "al vuelo" al consultarlo, el expediente NO puede reconstruir cómo estuvo el
--   paciente en el pasado: la pregunta "¿cómo estuvo mamá la semana pasada?" queda
--   sin respuesta histórica.
--
--   Esta tabla persiste una fotografía diaria del semáforo por paciente. Un job
--   la calcula al cierre de cada día (y puede recalcular el día en curso). Da
--   soporte real al "expediente histórico" que promete el producto y a la
--   analítica de tendencias de bienestar.

CREATE TABLE wellbeing_snapshots (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    uuid        NOT NULL,
    snapshot_date date        NOT NULL,
    status        varchar(12) NOT NULL,
    -- Motivos legibles que explican el estado (p. ej. "SpO2 bajo el mínimo",
    -- "1 dosis omitida"). jsonb INTENCIONAL: lista de razones heterogéneas que
    -- solo se muestran, no se consultan ni se cruzan.
    reasons       jsonb       NOT NULL DEFAULT '[]'::jsonb,
    -- Conteos que respaldan el cálculo, para auditar cómo se llegó al estado.
    vitals_out_of_range smallint NOT NULL DEFAULT 0,
    doses_missed        smallint NOT NULL DEFAULT 0,
    active_alerts       smallint NOT NULL DEFAULT 0,
    computed_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_wellbeing_snapshots_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
    -- Una fotografía por paciente y día: recalcular el mismo día actualiza la fila.
    CONSTRAINT uq_wellbeing_snapshots_day
        UNIQUE (patient_id, snapshot_date),
    CONSTRAINT ck_wellbeing_snapshots_status
        CHECK (status IN ('ok','warning','attention')),
    CONSTRAINT ck_wellbeing_snapshots_reasons_array
        CHECK (jsonb_typeof(reasons) = 'array')
);

-- Serie histórica del semáforo de un paciente (tendencia de bienestar).
CREATE INDEX ix_wellbeing_snapshots_patient
    ON wellbeing_snapshots (patient_id, snapshot_date DESC);

COMMENT ON TABLE  wellbeing_snapshots IS
    'Fotografía diaria del semáforo de bienestar por paciente (ok | warning | attention). Historiza un indicador que de otro modo se perdería al calcularse al vuelo, dando soporte al expediente histórico y a la analítica de tendencias.';
COMMENT ON COLUMN wellbeing_snapshots.reasons IS
    'Motivos legibles del estado del día. jsonb INTENCIONAL: lista de razones que solo se muestran.';
COMMENT ON COLUMN wellbeing_snapshots.vitals_out_of_range IS
    'Conteo de vitales fuera de rango ese día; respalda y audita el cálculo del estado.';

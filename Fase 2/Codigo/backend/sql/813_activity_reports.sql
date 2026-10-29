-- AgeCare — Bloque 8: Comunicación y acompañamiento
-- Tabla 13 de 13: activity_reports
-- Requisitos: RF-74 (generar reportes de actividad por rango de fechas)
--
-- Es la única tabla del bloque 8 que quedó sin dueño: el resto, 801 a 812, las
-- entregó el equipo. Esta cierra el bloque.
--
-- Guarda el REPORTE GENERADO, no el cálculo. Un reporte de actividad se arma
-- consultando scheduled_doses, care_observations, incidents, care_tasks y
-- shift_notes en un rango de fechas, pero el resultado hay que conservarlo por
-- tres razones:
--   · El familiar lo descarga y despues pregunta por él; tiene que seguir
--     existiendo igual que cuando se emitió.
--   · Si los datos de origen cambian después (una toma que se corrige), el
--     reporte ya entregado no puede cambiar retroactivamente.
--   · Deja rastro de quién sacó qué información del expediente y cuándo, que
--     es la misma preocupación de record_access_log.
--
-- Las cifras del resumen se guardan desnormalizadas a propósito, por lo mismo:
-- son el valor que tenía el indicador el día que se emitió, no el de hoy.

CREATE TABLE activity_reports (
    id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id     uuid         NOT NULL,
    requested_by   uuid         NOT NULL,
    period_from    date         NOT NULL,
    period_to      date         NOT NULL,
    status         varchar(12)  NOT NULL DEFAULT 'pending',

    -- Resumen congelado al momento de emitir
    doses_total    integer,
    doses_taken    integer,
    adherence_pct  numeric(5,2),
    observations   integer,
    incidents      integer,
    tasks_done     integer,

    -- Documento resultante
    storage_key    varchar(300),
    mime_type      varchar(100),
    size_bytes     bigint,

    generated_at   timestamptz,
    failure_reason varchar(200),
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_activity_reports_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_activity_reports_requested_by
        FOREIGN KEY (requested_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT uq_activity_reports_storage UNIQUE (storage_key),

    CONSTRAINT ck_activity_reports_periodo CHECK (period_to >= period_from),
    CONSTRAINT ck_activity_reports_status CHECK (
        status IN ('pending','ready','failed')
    ),
    -- Coherencia del ciclo: listo trae documento y fecha; fallido trae motivo.
    CONSTRAINT ck_activity_reports_ciclo CHECK (
        (status = 'pending' AND generated_at IS NULL AND storage_key IS NULL
                            AND failure_reason IS NULL)
     OR (status = 'ready'   AND generated_at IS NOT NULL AND storage_key IS NOT NULL
                            AND failure_reason IS NULL)
     OR (status = 'failed'  AND failure_reason IS NOT NULL AND storage_key IS NULL)
    ),
    CONSTRAINT ck_activity_reports_archivo CHECK (
        (storage_key IS NULL AND mime_type IS NULL AND size_bytes IS NULL)
     OR (storage_key IS NOT NULL AND mime_type IS NOT NULL AND size_bytes IS NOT NULL)
    ),
    CONSTRAINT ck_activity_reports_mime CHECK (
        mime_type IS NULL OR mime_type IN ('application/pdf','text/csv')
    ),
    CONSTRAINT ck_activity_reports_size
        CHECK (size_bytes IS NULL OR size_bytes BETWEEN 1 AND 26214400),
    CONSTRAINT ck_activity_reports_cifras CHECK (
        (doses_total   IS NULL OR doses_total   >= 0) AND
        (doses_taken   IS NULL OR doses_taken   >= 0) AND
        (observations  IS NULL OR observations  >= 0) AND
        (incidents     IS NULL OR incidents     >= 0) AND
        (tasks_done    IS NULL OR tasks_done    >= 0)
    ),
    -- No se pueden haber administrado más dosis de las programadas.
    CONSTRAINT ck_activity_reports_dosis CHECK (
        doses_total IS NULL OR doses_taken IS NULL OR doses_taken <= doses_total
    ),
    CONSTRAINT ck_activity_reports_adherencia CHECK (
        adherence_pct IS NULL OR adherence_pct BETWEEN 0 AND 100
    )
);

-- RF-74: los reportes de un paciente, del más nuevo al más viejo.
CREATE INDEX ix_activity_reports_patient
    ON activity_reports (patient_id, period_to DESC);

-- Cola de reportes por generar.
CREATE INDEX ix_activity_reports_pendientes
    ON activity_reports (created_at)
    WHERE status = 'pending';

CREATE TRIGGER tg_activity_reports_updated_at
    BEFORE UPDATE ON activity_reports
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  activity_reports IS
    'Reportes de actividad generados por rango de fechas. Conserva el documento emitido y el resumen congelado al momento de emitirlo, porque un reporte ya entregado no puede cambiar si los datos de origen se corrigen después. RF-74.';
COMMENT ON COLUMN activity_reports.id IS 'Identificador del reporte.';
COMMENT ON COLUMN activity_reports.patient_id IS 'Paciente sobre el que se emite el reporte.';
COMMENT ON COLUMN activity_reports.requested_by IS 'Usuario que lo solicitó. Deja rastro de quién extrajo información del expediente.';
COMMENT ON COLUMN activity_reports.period_from IS 'Inicio del rango cubierto.';
COMMENT ON COLUMN activity_reports.period_to IS 'Fin del rango cubierto.';
COMMENT ON COLUMN activity_reports.status IS 'Estado de la generación: pending, ready o failed.';
COMMENT ON COLUMN activity_reports.doses_total IS 'Tomas programadas en el período. Cifra congelada al emitir.';
COMMENT ON COLUMN activity_reports.doses_taken IS 'Tomas efectivamente administradas en el período.';
COMMENT ON COLUMN activity_reports.adherence_pct IS 'Adherencia del período, de 0 a 100. Congelada al emitir.';
COMMENT ON COLUMN activity_reports.observations IS 'Cantidad de observaciones de bitácora del período.';
COMMENT ON COLUMN activity_reports.incidents IS 'Cantidad de incidentes del período.';
COMMENT ON COLUMN activity_reports.tasks_done IS 'Tareas de cuidado completadas en el período.';
COMMENT ON COLUMN activity_reports.storage_key IS 'Ruta opaca del documento generado.';
COMMENT ON COLUMN activity_reports.mime_type IS 'Formato del documento: PDF o CSV.';
COMMENT ON COLUMN activity_reports.size_bytes IS 'Tamaño del documento en bytes.';
COMMENT ON COLUMN activity_reports.generated_at IS 'Momento en que el documento quedó disponible.';
COMMENT ON COLUMN activity_reports.failure_reason IS 'Motivo del fallo. Obligatorio cuando el estado es failed.';
COMMENT ON COLUMN activity_reports.created_at IS 'Fecha de creación del registro.';
COMMENT ON COLUMN activity_reports.updated_at IS 'Fecha de la última modificación del registro.';

-- ============================================================================
-- BLOQUE 6 · Auditoria y administracion
-- 604_activity_sessions.sql — Metricas de uso por sesion de actividad
-- Requisitos: RF-69 (registrar metricas de uso por sesion de actividad)
-- ----------------------------------------------------------------------------
-- Una sesion de actividad es un rato en que el adulto mayor uso una de las
-- funciones de su vista: mirar la galeria, escuchar contenido, crear musica
-- con el Director Musical, responder el check-in. RF-69 pide medirlo, y esa
-- medicion es lo que despues permite responder si la aplicacion se usa o no.
--
-- duration_seconds es columna generada y no calculada al vuelo porque las
-- consultas de uso agrupan y promedian duraciones; calcularla en cada consulta
-- impide indexarla. La resta de dos timestamptz da un interval, y extraer los
-- segundos de un interval SI es IMMUTABLE, que es lo que exige una columna
-- generada. Ojo: extraer de un timestamptz directamente es STABLE y Postgres
-- lo rechaza. Es el mismo problema que tuvo dose_text en medications.
-- ============================================================================

CREATE TABLE activity_sessions (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id         uuid        NOT NULL,
    elder_device_id    uuid,
    activity           varchar(20) NOT NULL,
    started_at         timestamptz NOT NULL,
    ended_at           timestamptz,
    duration_seconds   integer     GENERATED ALWAYS AS (
                           extract(epoch FROM (ended_at - started_at))::integer
                       ) STORED,
    interactions_count integer     NOT NULL DEFAULT 0,
    completed          boolean     NOT NULL DEFAULT false,
    meta               jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_activity_sessions_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_activity_sessions_device
        FOREIGN KEY (elder_device_id) REFERENCES elder_devices(id) ON DELETE RESTRICT,

    CONSTRAINT ck_activity_sessions_activity CHECK (
        activity IN ('gallery','music','reading','listening','chat',
                     'checkin','voice_message','vitals')
    ),
    CONSTRAINT ck_activity_sessions_orden CHECK (
        ended_at IS NULL OR ended_at >= started_at
    ),
    CONSTRAINT ck_activity_sessions_interactions CHECK (interactions_count >= 0),
    -- Una sesion sin cerrar no puede estar completada.
    CONSTRAINT ck_activity_sessions_completada CHECK (
        NOT completed OR ended_at IS NOT NULL
    )
);

-- RF-69: uso de un paciente en el tiempo.
CREATE INDEX ix_activity_sessions_patient
    ON activity_sessions (patient_id, started_at DESC);

-- Uso agregado por tipo de actividad, que es la metrica que se reporta.
CREATE INDEX ix_activity_sessions_activity
    ON activity_sessions (activity, started_at DESC);

-- Sesiones que quedaron abiertas: las cierra el proceso de limpieza.
CREATE INDEX ix_activity_sessions_abiertas
    ON activity_sessions (started_at)
    WHERE ended_at IS NULL;

COMMENT ON TABLE  activity_sessions IS 'Sesiones de uso de las actividades del adulto mayor, con su duracion e interacciones. Base de las metricas de uso. RF-69.';
COMMENT ON COLUMN activity_sessions.id IS 'Identificador de la sesion.';
COMMENT ON COLUMN activity_sessions.patient_id IS 'Adulto mayor que uso la actividad.';
COMMENT ON COLUMN activity_sessions.elder_device_id IS 'Dispositivo en que ocurrio la sesion. Nulo si fue desde otro cliente.';
COMMENT ON COLUMN activity_sessions.activity IS 'Actividad utilizada. Lista cerrada.';
COMMENT ON COLUMN activity_sessions.started_at IS 'Inicio de la sesion.';
COMMENT ON COLUMN activity_sessions.ended_at IS 'Fin de la sesion. Nulo mientras sigue abierta.';
COMMENT ON COLUMN activity_sessions.duration_seconds IS 'Duracion en segundos. Columna generada a partir de started_at y ended_at.';
COMMENT ON COLUMN activity_sessions.interactions_count IS 'Cantidad de interacciones del adulto mayor durante la sesion.';
COMMENT ON COLUMN activity_sessions.completed IS 'Si la actividad se llevo hasta el final.';
COMMENT ON COLUMN activity_sessions.meta IS 'Datos propios de cada actividad, en formato libre.';
COMMENT ON COLUMN activity_sessions.created_at IS 'Fecha de creacion del registro.';

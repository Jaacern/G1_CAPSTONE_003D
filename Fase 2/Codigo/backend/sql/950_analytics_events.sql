-- AgeCare — Bloque 10: Analítica
-- Tabla 1 de 1: analytics_events

CREATE TABLE analytics_events (
    id              uuid         NOT NULL DEFAULT gen_random_uuid(),
    occurred_at     timestamptz  NOT NULL DEFAULT now(),

    -- Qué pasó
    event_name      varchar(60)  NOT NULL,
    event_source    varchar(10)  NOT NULL,

    -- Quién lo hizo. Tres clases de actor, excluyentes entre sí.
    actor_type      varchar(10)  NOT NULL,
    actor_user_id   uuid,
    actor_device_id uuid,

    -- Sobre qué
    patient_id      uuid,
    entity_type     varchar(40),
    entity_id       uuid,

    -- Detalle propio del tipo de evento
    properties      jsonb        NOT NULL DEFAULT '{}'::jsonb,

    -- Correlación: todos los eventos de una misma petición comparten este id
    request_id      uuid,

    PRIMARY KEY (id, occurred_at),

    CONSTRAINT fk_analytics_events_actor_user
        FOREIGN KEY (actor_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_analytics_events_actor_device
        FOREIGN KEY (actor_device_id) REFERENCES elder_devices(id) ON DELETE RESTRICT,
    CONSTRAINT fk_analytics_events_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,

    -- Formato del nombre, no lista cerrada. Una lista cerrada obligaría a una
    -- migración cada vez que se quiera medir algo nuevo, y la gracia de esta
    -- tabla es poder agregar una métrica sin tocar el esquema.
    CONSTRAINT ck_analytics_events_name
        CHECK (event_name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'
               AND char_length(event_name) >= 3),
    CONSTRAINT ck_analytics_events_source
        CHECK (event_source IN ('app','api','job','device','admin')),
    CONSTRAINT ck_analytics_events_actor_type
        CHECK (actor_type IN ('user','elder','system')),

    -- Coherencia del actor: un evento de usuario trae usuario, uno del adulto
    -- mayor trae dispositivo, y uno del sistema no trae ninguno. Sin esto se
    -- podrían guardar eventos sin autor identificable y la analítica no
    -- podría distinguir quién hizo qué.
    CONSTRAINT ck_analytics_events_actor
        CHECK (
            (actor_type = 'user'   AND actor_user_id IS NOT NULL AND actor_device_id IS NULL)
         OR (actor_type = 'elder'  AND actor_device_id IS NOT NULL AND actor_user_id IS NULL)
         OR (actor_type = 'system' AND actor_user_id IS NULL AND actor_device_id IS NULL)
        ),

    -- La referencia de vuelta va completa o no va.
    CONSTRAINT ck_analytics_events_entity
        CHECK ((entity_type IS NULL) = (entity_id IS NULL)),

    -- properties tiene que ser un objeto. Un número o un arreglo suelto haría
    -- fallar cualquier consulta que lea una clave.
    CONSTRAINT ck_analytics_events_properties
        CHECK (jsonb_typeof(properties) = 'object')
) PARTITION BY RANGE (occurred_at);

-- Particiones mensuales por adelantado, igual que en vital_readings. La
-- partición DEFAULT recibe cualquier fecha fuera de rango para que una
-- inserción nunca falle por falta de partición.
DO $$
DECLARE
    mes date := date '2026-10-01';
    fin date := date '2028-01-01';
BEGIN
    WHILE mes < fin LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS analytics_events_%s '
            'PARTITION OF analytics_events FOR VALUES FROM (%L) TO (%L)',
            to_char(mes, 'YYYYMM'), mes, mes + interval '1 month'
        );
        mes := mes + interval '1 month';
    END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS analytics_events_default
    PARTITION OF analytics_events DEFAULT;

-- Inmutabilidad: un hecho ocurrido no se edita ni se borra. Mismo patrón que
-- audit_log. Si una métrica se calculó mal, se corrige con un evento nuevo.
CREATE OR REPLACE FUNCTION analytics_events_block_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'analytics_events es inmutable: no se permite %', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_analytics_events_no_update
    BEFORE UPDATE OR DELETE ON analytics_events
    FOR EACH ROW
    EXECUTE FUNCTION analytics_events_block_mutation();

-- Todo lo que pasó en un expediente, que es la consulta del informe familiar.
CREATE INDEX ix_analytics_events_patient
    ON analytics_events (patient_id, occurred_at DESC)
    WHERE patient_id IS NOT NULL;

-- Serie temporal de una métrica: cuántas dosis se confirmaron por semana,
-- cuántas alertas críticas hubo por mes.
CREATE INDEX ix_analytics_events_name
    ON analytics_events (event_name, occurred_at DESC);

-- Actividad de un usuario a través de todos sus pacientes.
CREATE INDEX ix_analytics_events_actor
    ON analytics_events (actor_user_id, occurred_at DESC)
    WHERE actor_user_id IS NOT NULL;

-- Búsqueda dentro del detalle del evento. jsonb_path_ops ocupa bastante menos
-- que el GIN por omisión y alcanza para el operador @>, que es el que se usa.
CREATE INDEX ix_analytics_events_properties
    ON analytics_events USING gin (properties jsonb_path_ops);

COMMENT ON TABLE  analytics_events IS
    'Flujo uniforme de hechos de la plataforma, particionado por mes e inmutable. Permite responder preguntas analíticas a dos o tres años sin unir las 41 tablas del modelo. Es la contraparte técnica de la política de no borrar nada.';
COMMENT ON COLUMN analytics_events.id IS
    'Identificador del evento. La clave primaria es (id, occurred_at) porque la tabla está particionada por fecha.';
COMMENT ON COLUMN analytics_events.occurred_at IS
    'Momento en que ocurrió el hecho. Es la clave de particionado.';
COMMENT ON COLUMN analytics_events.event_name IS
    'Nombre del evento en minúsculas, con puntos para jerarquía (dose.taken, alert.acknowledged). Se valida el formato, no una lista cerrada: agregar una métrica no debe requerir migración.';
COMMENT ON COLUMN analytics_events.event_source IS
    'De dónde vino: app (aplicación móvil), api, job (proceso automático), device (wearable o tablet), admin.';
COMMENT ON COLUMN analytics_events.actor_type IS
    'Clase de actor: user (persona con cuenta), elder (adulto mayor desde su dispositivo), system (proceso automático).';
COMMENT ON COLUMN analytics_events.actor_user_id IS
    'Usuario que originó el evento. Obligatorio cuando actor_type es user.';
COMMENT ON COLUMN analytics_events.actor_device_id IS
    'Dispositivo del adulto mayor que originó el evento. Obligatorio cuando actor_type es elder, porque el adulto mayor no tiene cuenta.';
COMMENT ON COLUMN analytics_events.patient_id IS
    'Paciente al que se refiere el evento. Nulo en eventos de cuenta que no involucran a ningún paciente.';
COMMENT ON COLUMN analytics_events.entity_type IS
    'Tabla del registro al que se refiere el evento, por ejemplo scheduled_doses.';
COMMENT ON COLUMN analytics_events.entity_id IS
    'Identificador del registro en esa tabla. Permite volver al dato autoritativo.';
COMMENT ON COLUMN analytics_events.properties IS
    'Detalle propio del tipo de evento. jsonb INTENCIONAL: los tipos de evento son heterogéneos y abiertos; normalizarlos significaría una tabla por tipo. Mismo criterio que audit_log.old_value.';
COMMENT ON COLUMN analytics_events.request_id IS
    'Identificador de la petición que generó el evento. Todos los eventos de una misma petición lo comparten, lo que permite reconstruir una acción completa.';

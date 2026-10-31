-- AgeCare — Turnos de cuidado
-- 921_care_shifts.sql — El turno de la cuidadora, con entrada y salida
--
-- La pantalla de check-in marca entrada y salida de turno con la ubicacion, y
-- la pantalla de inicio muestra si la cuidadora esta en turno o fuera. No
-- habia donde guardar nada de eso.
--
-- No sirve ninguna de las tablas que existen. daily_checkins es el check-in de
-- bienestar del adulto mayor, uno por dia. activity_sessions mide lo que el
-- adulto mayor hace en su dispositivo. shift_notes es la nota de relevo, que
-- es el texto que se deja al final del turno, no el turno.
--
-- Un turno es un hecho con principio y fin, asi que se guarda como una fila
-- que nace al entrar y se cierra al salir. El estado que la aplicacion muestra
-- no es una columna: es si existe o no una fila sin cerrar.

CREATE TABLE care_shifts (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id     uuid        NOT NULL,
    caregiver_id   uuid        NOT NULL,

    checked_in_at  timestamptz NOT NULL DEFAULT now(),
    checked_out_at timestamptz,

    -- Ubicacion de entrada y de salida. Con la misma precision que
    -- sos_events, que es la otra tabla del esquema que guarda coordenadas.
    in_latitude    numeric(9,6),
    in_longitude   numeric(9,6),
    out_latitude   numeric(9,6),
    out_longitude  numeric(9,6),

    -- La duracion se calcula, no se guarda a mano: dos columnas que tienen
    -- que coincidir son dos columnas que en algun momento no coinciden.
    duration_seconds integer   GENERATED ALWAYS AS (
                         extract(epoch FROM (checked_out_at - checked_in_at))::integer
                     ) STORED,

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_care_shifts_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_care_shifts_caregiver
        FOREIGN KEY (caregiver_id) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT ck_care_shifts_orden CHECK (
        checked_out_at IS NULL OR checked_out_at >= checked_in_at
    ),

    -- Una coordenada a medias no ubica nada.
    CONSTRAINT ck_care_shifts_coord_entrada CHECK (
        (in_latitude IS NULL) = (in_longitude IS NULL)
    ),
    CONSTRAINT ck_care_shifts_coord_salida CHECK (
        (out_latitude IS NULL) = (out_longitude IS NULL)
    ),
    -- No puede haber ubicacion de salida en un turno que no salio.
    CONSTRAINT ck_care_shifts_salida_coherente CHECK (
        checked_out_at IS NOT NULL OR out_latitude IS NULL
    ),

    CONSTRAINT ck_care_shifts_lat CHECK (
        (in_latitude  IS NULL OR in_latitude  BETWEEN -90  AND 90)
    AND (out_latitude IS NULL OR out_latitude BETWEEN -90  AND 90)
    ),
    CONSTRAINT ck_care_shifts_lng CHECK (
        (in_longitude  IS NULL OR in_longitude  BETWEEN -180 AND 180)
    AND (out_longitude IS NULL OR out_longitude BETWEEN -180 AND 180)
    )
);

-- Una cuidadora tiene un solo turno abierto a la vez, no importa el paciente:
-- no puede estar en dos casas al mismo tiempo. Lo garantiza el motor, no la
-- aplicacion, porque dos toques rapidos del boton de entrada llegan como dos
-- peticiones en paralelo y una validacion por consulta previa las deja pasar
-- las dos.
CREATE UNIQUE INDEX uq_care_shifts_abierto
    ON care_shifts (caregiver_id)
    WHERE checked_out_at IS NULL;

-- La bitacora y los informes piden los turnos de un paciente por fecha.
CREATE INDEX ix_care_shifts_patient_fecha
    ON care_shifts (patient_id, checked_in_at DESC);

-- Los informes de la cuidadora piden sus propios turnos cerrados.
CREATE INDEX ix_care_shifts_caregiver_fecha
    ON care_shifts (caregiver_id, checked_in_at DESC);

-- El trigger va aca y no en 916, que ya corrio antes de que esta tabla
-- existiera. Una tabla nueva con updated_at trae su propio trigger.
CREATE TRIGGER tg_care_shifts_updated_at
    BEFORE UPDATE ON care_shifts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE care_shifts IS
    'Turno de cuidado con marca de entrada y salida. Una fila sin checked_out_at es un turno en curso.';
COMMENT ON COLUMN care_shifts.duration_seconds IS
    'Duracion del turno en segundos, calculada por el motor. NULL mientras el turno sigue abierto.';

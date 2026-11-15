-- AgeCare — Bloque 4: Alertas y emergencias
-- 963_avisos_de_alertas.sql — Lo que falta para avisar de verdad (RF-45, RF-52)
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--     Las alertas se creaban y nadie se enteraba. alert_deliveries existe
--     desde el bloque 4 para registrar cada aviso, pero ningun proceso
--     escribia en ella: la unica forma de saber de una caida era tener la
--     aplicacion abierta en el centro de alertas.
--
--     El envio lo hace app/avisos.py. Esto es lo que ese proceso necesita
--     que la base recuerde.
--
-- alerts.notified_at
--     Cuando se repartio el aviso de esta alerta. Hace falta un campo y no
--     basta con mirar si hay filas en alert_deliveries, porque una alerta
--     puede no tener a quien avisar (un paciente cuyo circulo desactivo ese
--     tipo de aviso): sin la marca, esa alerta se volveria a evaluar en cada
--     pasada para siempre.
--
--     Tambien es lo que evita avisar dos veces. Quien reparte primero marca
--     la fila con un UPDATE que exige notified_at IS NULL, asi que si dos
--     procesos llegan a la vez solo uno la toma.
--
-- alerts.renotify_count  y  alerts.escalated_at
--     RF-52. El requisito original pedia escalar "a los siguientes
--     contactos". Con 406 los contactos dejaron de tener orden: en una
--     emergencia se avisa a todos por igual. Lo que queda del requisito, y lo
--     que de verdad protege al paciente, es no dejar morir una alerta critica
--     que nadie atendio: se vuelve a avisar a todos cada
--     alert_escalation_minutes mientras siga sin atender.
--
--     escalated_at ya existia (401) y pasa a guardar el ultimo reaviso.
--     renotify_count cuenta cuantos van, para poder ponerle techo
--     (alert_renotify_max): un telefono que suena cada quince minutos durante
--     tres dias deja de ser un aviso y pasa a ser ruido que se apaga.
--
-- alert_deliveries.notice_round
--     A que vuelta pertenece cada entrega: 0 es el primer aviso, 1 el primer
--     reaviso. Sin esto las entregas de un reaviso no se distinguen de las
--     del aviso original y no se puede responder "cuantas veces hubo que
--     insistir hasta que alguien atendio".

ALTER TABLE alerts
    ADD COLUMN IF NOT EXISTS notified_at    timestamptz,
    ADD COLUMN IF NOT EXISTS renotify_count smallint NOT NULL DEFAULT 0;

ALTER TABLE alerts DROP CONSTRAINT IF EXISTS ck_alerts_renotify_count;
ALTER TABLE alerts ADD CONSTRAINT ck_alerts_renotify_count
    CHECK (renotify_count >= 0);

-- El reaviso solo tiene sentido despues del primer aviso.
ALTER TABLE alerts DROP CONSTRAINT IF EXISTS ck_alerts_escalated_after_notice;
ALTER TABLE alerts ADD CONSTRAINT ck_alerts_escalated_after_notice
    CHECK (renotify_count = 0 OR notified_at IS NOT NULL);

-- Lo que el repartidor busca en cada pasada: alertas sin repartir. Parcial,
-- porque casi todas las filas de la tabla ya estan repartidas.
CREATE INDEX IF NOT EXISTS ix_alerts_sin_avisar
    ON alerts (created_at) WHERE notified_at IS NULL;

ALTER TABLE alert_deliveries
    ADD COLUMN IF NOT EXISTS notice_round smallint NOT NULL DEFAULT 0;

ALTER TABLE alert_deliveries DROP CONSTRAINT IF EXISTS ck_alert_deliveries_round;
ALTER TABLE alert_deliveries ADD CONSTRAINT ck_alert_deliveries_round
    CHECK (notice_round >= 0);

-- Lo que el repartidor envia en cada pasada.
CREATE INDEX IF NOT EXISTS ix_alert_deliveries_queued
    ON alert_deliveries (created_at) WHERE status = 'queued';

INSERT INTO system_parameters (key, value, value_type, description) VALUES
    ('alert_renotify_max', '8', 'int',
     'Cuantas veces como maximo se vuelve a avisar de una alerta critica que nadie atiende (RF-52). Con alert_escalation_minutes en 15, ocho reavisos cubren dos horas.')
ON CONFLICT (key) DO NOTHING;

UPDATE system_parameters
   SET description = 'Minutos sin atencion tras los cuales se vuelve a avisar a todos de una alerta critica (RF-52). No hay orden entre contactos: se avisa a todos por igual (406).'
 WHERE key = 'alert_escalation_minutes';

COMMENT ON COLUMN alerts.notified_at IS
    'Momento en que se repartio el aviso de esta alerta (RF-45). NULL = todavia no se reparte. Lo escribe app/avisos.py.';
COMMENT ON COLUMN alerts.renotify_count IS
    'Cuantas veces se volvio a avisar por falta de atencion (RF-52). Tiene techo en alert_renotify_max.';
COMMENT ON COLUMN alerts.escalated_at IS
    'Momento del ultimo reaviso por falta de atencion (RF-52). NULL = no hizo falta insistir. Los contactos no tienen orden (406): el reaviso va a todos.';
COMMENT ON COLUMN alert_deliveries.notice_round IS
    'Vuelta a la que pertenece la entrega: 0 = primer aviso, 1 = primer reaviso, y asi.';

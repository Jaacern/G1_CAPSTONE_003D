-- AgeCare — Bloque 3: Medicamentos y adherencia
-- 968_dosis_cancelada.sql — Estado 'cancelled' para las tomas que ya no van
-- MIGRACION IDEMPOTENTE
--
-- EL PROBLEMA
--     Las tomas se generan con dias de anticipacion. Cuando el medico
--     descontinua un medicamento o cambia sus horarios (RF-26, RF-27), las
--     que ya estaban generadas se quedaban ahi: al adulto mayor le seguian
--     apareciendo tomas de un remedio que ya no toma, el barrido horario las
--     pasaba a 'missed' por no confirmarlas, y la adherencia le bajaba a una
--     persona que hizo todo bien.
--
-- POR QUE UN ESTADO Y NO BORRAR LAS FILAS
--     Se evaluaron las dos. Borrar deja la tabla mas limpia, pero el
--     expediente pierde el rastro de que esa toma existio y de cuando dejo
--     de corresponder. En un expediente clinico eso importa: la pregunta
--     "por que el martes no hubo dosis de las 20:00" tiene que tener
--     respuesta, y la respuesta es que ese dia se cambio la indicacion.
--
--     Ademas el UNIQUE (medication_id, scheduled_at) convierte a la fila
--     cancelada en una marca: el generador la reconoce y, si esa misma hora
--     vuelve a estar en el plan, la revive en vez de crear una duplicada.
--
-- QUE NO CUENTA
--     Una toma cancelada no es una toma omitida. No entra en la adherencia
--     (no suma ni como tomada ni como no tomada), no genera alerta y no sale
--     en la pantalla del dia. Para eso basta con que su estado sea distinto,
--     porque todo eso ya filtra por estado.

ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_status;
ALTER TABLE scheduled_doses ADD CONSTRAINT ck_scheduled_doses_status CHECK (
    status IN ('pending', 'taken', 'skipped', 'postponed', 'missed',
               'adverse', 'cancelled')
);

-- Lo que busca el generador al revivir, y lo que se cancela al cambiar un
-- plan: las tomas de un medicamento o indicacion a partir de cierto momento.
CREATE INDEX IF NOT EXISTS ix_scheduled_doses_cancelables
    ON scheduled_doses (scheduled_at)
    WHERE status IN ('pending', 'postponed');

COMMENT ON COLUMN scheduled_doses.status IS
    'pending | taken | skipped | postponed | missed | adverse | cancelled. ''cancelled'' la pone el sistema cuando la toma deja de corresponder porque cambio o se descontinuo la indicacion (RF-26, RF-27): no es una toma omitida y no cuenta en la adherencia.';

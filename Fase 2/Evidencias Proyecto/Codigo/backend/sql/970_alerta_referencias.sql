-- Referencias de la alerta en columnas propias (corrige la excepcion de
-- alerts.payload).
--
-- EL PROBLEMA
--   401_alerts.sql documenta alerts.payload como una excepcion a 1FN "porque
--   estos datos no se consultan ni se cruzan: solo se muestran". Es falso: el
--   sistema SI los cruza. maintenance.py busca 'dose_id' y 'reading_id' dentro
--   del jsonb para no repetir una alerta por la misma dosis o lectura, y una
--   prueba hace un JOIN contra 'reading_id'. Al vivir en el jsonb esas
--   referencias no tienen clave foranea (pueden quedar colgadas), no tienen
--   indice, y la unicidad de "una alerta por dosis" dependia de un NOT EXISTS
--   sobre texto, sin restriccion, que dos procesos en paralelo podian saltarse.
--
-- EL ARREGLO
--   Se sacan esas dos referencias a columnas propias:
--     - dose_id    uuid, con FK a scheduled_doses(id).
--     - reading_id uuid, SIN FK. vital_readings tiene PK compuesta
--       (id, measured_at) por ser particionada, y PostgreSQL no admite una FK
--       que apunte solo a id. Se indexa igual.
--   La unicidad queda garantizada por indices unicos, no por codigo:
--     - una alerta de cada tipo por dosis (dose_id, type).
--     - una alerta por lectura (reading_id).
--   El payload se conserva para el detalle que se muestra; su comentario se
--   corrige para que diga la verdad.
--
-- ORDEN: primero se rellenan las columnas desde el payload (sin FK, para no
-- fallar si ya hay una referencia colgada), luego se verifica que no queden
-- huerfanas ni duplicadas, y recien ahi se ponen la FK y los indices unicos.
-- Si algo de eso existe en los datos, la migracion se detiene con un mensaje
-- claro (es atomica, no deja nada a medias) en vez de romper con un error
-- criptico.

ALTER TABLE alerts
    ADD COLUMN dose_id    uuid,
    ADD COLUMN reading_id uuid;

-- 1. Traer a las columnas lo que hoy vive en el jsonb (todavia sin FK).
UPDATE alerts
   SET dose_id = (payload ->> 'dose_id')::uuid
 WHERE dose_id IS NULL
   AND payload ? 'dose_id'
   AND btrim(payload ->> 'dose_id') <> '';

UPDATE alerts
   SET reading_id = (payload ->> 'reading_id')::uuid
 WHERE reading_id IS NULL
   AND payload ? 'reading_id'
   AND btrim(payload ->> 'reading_id') <> '';

-- 2. Referencias colgadas: un dose_id que no existe en scheduled_doses. Son el
--    sintoma del bug (vivian en el jsonb sin FK). Si hay, hay que decidir que
--    hacer con ellas antes de poner la FK.
DO $$
DECLARE colgadas int;
BEGIN
    SELECT count(*) INTO colgadas
      FROM alerts a
     WHERE a.dose_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM scheduled_doses d WHERE d.id = a.dose_id);
    IF colgadas > 0 THEN
        RAISE EXCEPTION
          'Hay % alertas cuyo dose_id no existe en scheduled_doses (referencias '
          'colgadas del payload). Hay que decidir si se anulan o se investigan '
          'antes de agregar la FK. Avisa a quien aplica la migracion.', colgadas;
    END IF;
END $$;

-- 3. Ahora que esta limpio, la FK.
ALTER TABLE alerts
    ADD CONSTRAINT fk_alerts_dose
        FOREIGN KEY (dose_id) REFERENCES scheduled_doses (id) ON DELETE RESTRICT;

-- 4. Duplicados: dos alertas del mismo tipo para la misma dosis, o dos para la
--    misma lectura (el bug que el indice unico va a impedir de aqui en mas).
DO $$
DECLARE duplicados int;
BEGIN
    SELECT count(*) INTO duplicados FROM (
        SELECT 1 FROM alerts
         WHERE dose_id IS NOT NULL
         GROUP BY dose_id, type HAVING count(*) > 1
        UNION ALL
        SELECT 1 FROM alerts
         WHERE reading_id IS NOT NULL
         GROUP BY reading_id HAVING count(*) > 1
    ) t;
    IF duplicados > 0 THEN
        RAISE EXCEPTION
          'Hay % dosis/lecturas con mas de una alerta (conservar la mas antigua '
          'por (dose_id, type) y por reading_id, y borrar las demas, antes de '
          'crear el indice unico). Avisa a quien aplica la migracion.', duplicados;
    END IF;
END $$;

-- 5. Idempotencia real, impuesta por el motor y no por el codigo.
CREATE UNIQUE INDEX ux_alerts_dose
    ON alerts (dose_id, type) WHERE dose_id IS NOT NULL;
CREATE UNIQUE INDEX ux_alerts_reading
    ON alerts (reading_id) WHERE reading_id IS NOT NULL;

COMMENT ON COLUMN alerts.dose_id IS
    'Dosis que origino la alerta (missed_dose, o incident por evento adverso). FK a scheduled_doses. Reemplaza al dose_id que vivia en payload. Unico por (dose_id, type): una alerta de cada tipo por dosis.';
COMMENT ON COLUMN alerts.reading_id IS
    'Lectura de signo vital que origino la alerta (vital_out_of_range). Sin FK: vital_readings tiene PK compuesta (id, measured_at) por ser particionada. Unico: una alerta por lectura.';
COMMENT ON COLUMN alerts.payload IS
    'Detalle variable para MOSTRAR al abrir la alerta (valor, limites, nombre del farmaco, etc.), que cambia segun el tipo. Las referencias que el sistema cruza viven en columnas propias (dose_id, reading_id), no aqui. Excepcion a 1FN acotada a datos de solo presentacion.';

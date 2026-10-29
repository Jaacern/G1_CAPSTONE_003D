-- AgeCare — Integridad transversal
-- 916_triggers_updated_at.sql — Ninguna tabla con updated_at queda sin su trigger
--
-- EL PROBLEMA
--   001_base.sql define set_updated_at(), la función compartida que refresca
--   updated_at en cada UPDATE. Pero el trigger hay que colgarlo tabla por tabla,
--   y a medida que el modelo creció a 65 tablas, once quedaron con la columna y
--   sin el trigger:
--
--     care_observations   content_items      daily_checkins    elder_devices
--     files               incidents          medical_documents plan_limits
--     plans               shift_notes        usage_counters
--
--   El síntoma es silencioso y por eso peligroso: la columna existe, los INSERT
--   la llenan con su DEFAULT, y nadie nota nada. Pero al modificar una fila
--   updated_at se queda con la fecha de creación. Cualquier consulta que diga
--   "qué cambió desde ayer" devuelve resultados incompletos, y la sincronización
--   sin conexión de RF-81, que necesita justamente eso, no podría funcionar.
--
-- LA CORRECCIÓN
--   En vez de escribir once CREATE TRIGGER a mano, se recorre el catálogo y se
--   le pone el trigger a toda tabla que tenga updated_at y no lo tenga. Así
--   queda resuelto hoy y, si mañana alguien agrega una tabla nueva y se olvida
--   del trigger, basta volver a correr este archivo.
--
--   Es idempotente: sobre una base que ya los tenga, no hace nada.

DO $$
DECLARE
    t record;
    creados integer := 0;
BEGIN
    FOR t IN
        SELECT c.oid, c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.oid
                             AND a.attname  = 'updated_at'
                             AND NOT a.attisdropped
         WHERE n.nspname = 'public'
           AND c.relkind = 'r'
           AND NOT c.relispartition
           AND NOT EXISTS (
                 SELECT 1 FROM pg_trigger tg
                  WHERE tg.tgrelid = c.oid
                    AND NOT tg.tgisinternal
                    AND tg.tgname = 'tg_' || c.relname || '_updated_at')
         ORDER BY c.relname
    LOOP
        EXECUTE format(
            'CREATE TRIGGER tg_%1$s_updated_at '
            'BEFORE UPDATE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t.relname);
        creados := creados + 1;
        RAISE NOTICE 'trigger creado en %', t.relname;
    END LOOP;

    RAISE NOTICE 'triggers de updated_at creados: %', creados;
END $$;

-- Comprobación: si alguna tabla quedara sin su trigger, la carga se detiene
-- acá en vez de dejar el problema pasar en silencio otra vez.
DO $$
DECLARE
    faltan text;
BEGIN
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO faltan
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid
                         AND a.attname  = 'updated_at'
                         AND NOT a.attisdropped
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND NOT c.relispartition
       AND NOT EXISTS (
             SELECT 1 FROM pg_trigger tg
              WHERE tg.tgrelid = c.oid
                AND NOT tg.tgisinternal
                AND tg.tgname LIKE 'tg\_%\_updated\_at');

    IF faltan IS NOT NULL THEN
        RAISE EXCEPTION 'Quedaron tablas con updated_at y sin trigger: %', faltan;
    END IF;
END $$;

COMMENT ON FUNCTION set_updated_at() IS
    'Trigger compartido: refresca updated_at en cada UPDATE. Se cuelga de toda tabla que tenga la columna; 916_triggers_updated_at.sql lo garantiza y falla si alguna queda sin él.';

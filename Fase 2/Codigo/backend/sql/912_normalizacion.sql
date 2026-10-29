-- AgeCare — Correcciones de normalización
-- 912_normalizacion.sql — Cierre de 3FN en subscriptions y justificación de 1FN
--
-- ===========================================================================
-- 1. subscriptions.plan — dependencia transitiva (3FN)
-- ===========================================================================
-- subscriptions quedó con dos columnas que dicen lo mismo:
--     plan     varchar(20)  texto suelto, 'free' o 'premium'
--     plan_id  uuid         referencia al catálogo plans
--
-- plan se deduce de plan_id pasando por plans.code, o sea depende de un
-- atributo que no es clave. Eso es dependencia transitiva y rompe 3FN.
--
-- La columna existía como puente mientras el bloque 7 no estaba construido.
-- Ya está construido, y se verificó que ningún archivo .py del backend la lee,
-- así que botarla no rompe la API.
--
-- Antes de botarla se completa plan_id en las filas que todavía lo tengan nulo,
-- para no perder la información que guardaba el texto.

INSERT INTO plans (code, name, tier, status, published_at)
SELECT DISTINCT s.plan, initcap(s.plan), CASE WHEN s.plan = 'free' THEN 0 ELSE 1 END,
       'active', now()
  FROM subscriptions s
 WHERE s.plan IS NOT NULL
   AND s.plan_id IS NULL
   AND NOT EXISTS (SELECT 1 FROM plans p WHERE p.code = s.plan)
ON CONFLICT (code) DO NOTHING;

UPDATE subscriptions s
   SET plan_id = p.id
  FROM plans p
 WHERE p.code = s.plan
   AND s.plan_id IS NULL;

ALTER TABLE subscriptions DROP COLUMN IF EXISTS plan;

-- Ahora que el texto no está, el plan contratado es obligatorio.
ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS ck_subscriptions_plan_id;
ALTER TABLE subscriptions
    ADD CONSTRAINT ck_subscriptions_plan_id CHECK (plan_id IS NOT NULL) NOT VALID;

COMMENT ON COLUMN subscriptions.plan_id IS
    'Plan contratado. Única referencia al catálogo de planes. Reemplazó a la columna de texto plan, que duplicaba plans.code y rompía 3FN.';

-- ===========================================================================
-- 2. wellbeing_snapshots.reasons — excepción documentada a 1FN
-- ===========================================================================
-- reasons es jsonb y guarda una lista. Una lista homogénea de un atributo
-- conocido es justo lo que 1FN prohíbe, y es la misma forma que tenía
-- patients.conditions antes de normalizarse a patient_conditions.
--
-- Se mantiene como jsonb, pero la justificación tenía una línea y hay que poder
-- defenderla. Estas son las tres razones, al nivel de detalle de alerts.payload:
--
--   · Los motivos son TEXTO YA REDACTADO para mostrar, no datos. Dicen cosas
--     como "2 dosis omitidas hoy" o "presión fuera de rango". No son códigos
--     de un catálogo cerrado.
--   · No se consultan ni se cruzan NUNCA. La aplicación no filtra semáforos por
--     motivo ni los agrupa; los lee enteros para pintarlos en pantalla. Una
--     tabla hija daría integridad sobre algo que nadie consulta.
--   · Las cifras que sí se analizan ya están normalizadas al lado, en
--     vitals_out_of_range, doses_missed y active_alerts. El análisis se hace
--     sobre esas tres columnas, no sobre el texto.
--
-- La diferencia con patient_conditions es esa: una condición médica se consulta,
-- se filtra y se cruza; un motivo del semáforo solo se muestra.

COMMENT ON COLUMN wellbeing_snapshots.reasons IS
    'Motivos del estado del día, como texto ya redactado para mostrar. jsonb INTENCIONAL y excepción documentada a 1FN: no son códigos de un catálogo, nunca se consultan ni se cruzan, y las cifras que sí se analizan están normalizadas en vitals_out_of_range, doses_missed y active_alerts. Normalizarlo daría integridad sobre datos que solo se pintan en pantalla.';

-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 708_subscriptions_plan.sql — Conectar subscriptions con plans
-- Requisitos: RF-73, RF-83 a RF-85
-- ----------------------------------------------------------------------------
-- subscriptions ya existe (501_subscriptions.sql) con la columna plan como
-- varchar(20) y el comentario 'free|premium'. Ese texto no es una relacion:
-- nada impide escribir 'Premium', 'prem' o 'oro', y no hay forma de llegar
-- desde una suscripcion a lo que ese plan incluye.
--
-- Este archivo AGREGA plan_id y lo apunta a plans. No borra ni modifica la
-- columna plan, a proposito: la API en produccion la lee hoy, y quitarla
-- rompe el servicio. Queda como columna heredada hasta que el codigo migre a
-- plan_id; recien entonces corresponde eliminarla, en su propio archivo.
--
-- Por eso este cambio va en un archivo aparte y no editando
-- 501_subscriptions.sql: ese archivo lo mantiene el equipo y ya corrio en
-- todos los entornos. Un ALTER posterior es trazable; reescribir el original
-- hace que la BD creada ayer y la creada hoy no sean la misma.
-- ============================================================================

ALTER TABLE subscriptions
    ADD COLUMN IF NOT EXISTS plan_id uuid;

ALTER TABLE subscriptions
    DROP CONSTRAINT IF EXISTS fk_subscriptions_plan;

ALTER TABLE subscriptions
    ADD CONSTRAINT fk_subscriptions_plan
        FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE RESTRICT;

-- Rellena plan_id en las suscripciones que ya existen, emparejando por codigo.
-- Es idempotente: solo toca las filas que todavia no lo tienen.
UPDATE subscriptions s
   SET plan_id = p.id
  FROM plans p
 WHERE p.code = s.plan
   AND s.plan_id IS NULL;

-- Suscripciones por plan, la consulta de las metricas de conversion.
CREATE INDEX IF NOT EXISTS ix_subscriptions_plan_id
    ON subscriptions (plan_id, status);

COMMENT ON COLUMN subscriptions.plan_id IS 'Plan contratado. Es la referencia valida al catalogo de planes.';
COMMENT ON COLUMN subscriptions.plan IS 'Codigo del plan como texto. Columna heredada que se conserva mientras la API migra a plan_id; no usar en desarrollo nuevo.';

-- AgeCare — Bloque 7: Planes y suscripciones
-- 910_limit_keys.sql — Corrección de 2FN sobre plan_limits
--
-- EL PROBLEMA
--   plan_limits tiene clave primaria compuesta (plan_id, limit_key) y, entre sus
--   atributos, la columna unit. Pero unit NO depende de la clave completa:
--   depende SOLO de limit_key. "max_patients" se mide en count sea cual sea el
--   plan, y "history_days" en days siempre. Eso es una dependencia parcial, que
--   es exactamente lo que prohíbe la segunda forma normal.
--
--   El síntoma práctico: con tres planes, la unidad de max_patients está escrita
--   tres veces, y nada impide que una diga count y otra days.
--
-- LA CORRECCIÓN
--   Se saca limit_key a su propio catálogo, que es donde esa unidad sí depende
--   de la clave completa, y plan_limits pasa a referenciarlo. De paso gana
--   integridad referencial sobre el nombre del límite, que antes era solo un
--   CHECK de formato y permitía escribir cualquier cosa.
--
--   Es la misma corrección que ya se aplicó en este modelo con vital_types y
--   con features.

CREATE TABLE limit_keys (
    key         varchar(40)  PRIMARY KEY,
    label       varchar(80)  NOT NULL,
    description varchar(300) NOT NULL,
    unit        varchar(20)  NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT ck_limit_keys_key CHECK (key ~ '^[a-z][a-z0-9_]{2,39}$'),
    CONSTRAINT ck_limit_keys_label CHECK (btrim(label) <> ''),
    CONSTRAINT ck_limit_keys_unit CHECK (
        unit IN ('count','days','months','megabytes','per_month','per_day')
    )
);

COMMENT ON TABLE  limit_keys IS
    'Catálogo de límites que un plan puede imponer. Existe para corregir una dependencia parcial de 2FN: la unidad de medida depende del límite, no del plan que lo usa.';
COMMENT ON COLUMN limit_keys.key IS 'Nombre del límite, por ejemplo max_patients. Es lo que consulta la aplicación.';
COMMENT ON COLUMN limit_keys.label IS 'Nombre visible del límite.';
COMMENT ON COLUMN limit_keys.description IS 'Qué limita exactamente, en lenguaje de usuario.';
COMMENT ON COLUMN limit_keys.unit IS 'Unidad en que se expresa. Depende del límite y de nada más, que es la razón de esta tabla.';
COMMENT ON COLUMN limit_keys.created_at IS 'Fecha de creación del registro.';

-- Los límites que el modelo ya contemplaba.
INSERT INTO limit_keys (key, label, description, unit) VALUES
 ('max_patients',     'Pacientes',            'Cuántos adultos mayores puede seguir la cuenta.',          'count'),
 ('max_members',      'Miembros por círculo', 'Cuántas personas puede tener el círculo de cuidado.',      'count'),
 ('history_days',     'Días de historial',    'Cuánto historial de mediciones queda visible.',            'days'),
 ('max_storage_mb',   'Almacenamiento',       'Espacio para documentos y fotos del expediente.',          'megabytes'),
 ('ai_queries_month', 'Consultas al asistente','Consultas al asistente de IA permitidas por mes.',        'per_month')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- plan_limits pasa a apuntar al catálogo y deja de guardar la unidad.
-- Se rellena primero el catálogo con cualquier clave que ya estuviera en uso,
-- para que el ALTER no falle sobre una base con datos.
-- ---------------------------------------------------------------------------
INSERT INTO limit_keys (key, label, description, unit)
SELECT DISTINCT pl.limit_key, pl.limit_key, 'Límite heredado, pendiente de documentar.', pl.unit
  FROM plan_limits pl
 WHERE NOT EXISTS (SELECT 1 FROM limit_keys lk WHERE lk.key = pl.limit_key);

ALTER TABLE plan_limits DROP CONSTRAINT IF EXISTS ck_plan_limits_key;

ALTER TABLE plan_limits
    ADD CONSTRAINT fk_plan_limits_key
        FOREIGN KEY (limit_key) REFERENCES limit_keys(key) ON DELETE RESTRICT;

-- La unidad ya vive en el catálogo. Aquí sobraba y era la dependencia parcial.
ALTER TABLE plan_limits DROP COLUMN IF EXISTS unit;

COMMENT ON TABLE plan_limits IS
    'Valor de cada límite para cada plan. Cumple 2FN: limit_value depende de la clave completa (plan_id, limit_key). La unidad se movió a limit_keys porque dependía solo del límite. RF-73, RF-83 a RF-85.';
COMMENT ON COLUMN plan_limits.limit_key IS
    'Límite que se está fijando. Apunta al catálogo limit_keys.';

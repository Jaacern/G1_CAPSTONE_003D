-- AgeCare — Bloque 3: Medicación
-- 311_treatment_item_drug_link.sql — Vínculo de la indicación con el catálogo + intervalo SOS
--
-- POR QUÉ
--   La indicación validaba su dosis contra drug_catalog al crearse, pero no
--   guardaba de qué fármaco del catálogo venía. Sin ese vínculo no se puede
--   controlar después el máximo de 24 h de un SOS (bromuro de ipratropio:
--   hasta 12 puff al día) ni revalidar la dosis al versionar el tratamiento.
--   Además, un SOS suele indicarse con un intervalo mínimo ("cada 6 h si
--   necesita"): se guarda en minutos para advertir un uso demasiado seguido.
--
-- Corrección de normalización (mismo criterio que vital_readings → vital_types):
--   · drug_code es FK a drug_catalog(code), la fuente única del fármaco. No se
--     copian unidad, rango ni máximo diario a la indicación (3FN): se leen del
--     catálogo cuando hacen falta.

ALTER TABLE treatment_items
    ADD COLUMN IF NOT EXISTS drug_code            varchar(40),
    ADD COLUMN IF NOT EXISTS prn_min_interval_min smallint;

ALTER TABLE treatment_items DROP CONSTRAINT IF EXISTS fk_treatment_items_drug;
ALTER TABLE treatment_items ADD CONSTRAINT fk_treatment_items_drug
    FOREIGN KEY (drug_code) REFERENCES drug_catalog(code) ON DELETE RESTRICT;

-- El intervalo solo tiene sentido en un SOS, y va de 15 minutos a 24 horas.
ALTER TABLE treatment_items DROP CONSTRAINT IF EXISTS ck_treatment_items_prn_interval;
ALTER TABLE treatment_items ADD CONSTRAINT ck_treatment_items_prn_interval CHECK (
    prn_min_interval_min IS NULL
    OR (is_prn AND prn_min_interval_min BETWEEN 15 AND 1440)
);

COMMENT ON COLUMN treatment_items.drug_code IS
    'Fármaco del catálogo del que viene la indicación (FK a drug_catalog). NULL si se indicó como texto libre. Permite aplicar el máximo de 24 h a los SOS.';
COMMENT ON COLUMN treatment_items.prn_min_interval_min IS
    'Solo SOS: intervalo mínimo entre usos, en minutos (360 = cada 6 h). Un uso antes de tiempo se advierte y queda marcado.';

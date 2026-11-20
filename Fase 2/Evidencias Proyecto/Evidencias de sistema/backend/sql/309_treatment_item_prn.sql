-- AgeCare — Bloque 3: Medicación
-- 309_treatment_item_prn.sql — Indicaciones SOS/condicional + etiqueta de horario (Fase 4)
--
-- POR QUÉ (caso real)
--   La ficha de Rosa incluye "bromuro de ipratropio 2 puff cada 6 h SOS EN CASO
--   DE EMERGENCIA". Eso es una indicación CONDICIONAL: no se toma en un horario
--   fijo, se usa solo si hace falta. No debe generar agenda de dosis; se
--   registra cuando se usa.
--
--   Además, el caso lista las tomas "con el desayuno / almuerzo / once / al
--   acostarse". Decisión del equipo: Opción B (etiqueta visible), sin cambiar el
--   motor de horarios. Se agrega schedule_label como texto de referencia que el
--   médico pone junto a la hora; la frecuencia real sigue siendo HH:MM.
--
--   Fuente: nomenclatura de prescripción (SOS/PRN "pro re nata") y los 5
--   correctos; ver docs/PLAN_IMPLEMENTACION_FICHA_CLINICA.md secciones 6 y 7.

ALTER TABLE treatment_items
    ADD COLUMN IF NOT EXISTS is_prn         boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS schedule_label varchar(40);

COMMENT ON COLUMN treatment_items.is_prn IS
    'true = indicación condicional / SOS (pro re nata): NO genera dosis en la agenda; se registra al usarse. false = programada (genera agenda por horarios).';
COMMENT ON COLUMN treatment_items.schedule_label IS
    'Etiqueta de referencia del momento de toma ("con el desayuno", "en ayunas"). Opcional. Es ayuda para el paciente; la frecuencia real son los horarios (medication/treatment_item_times).';

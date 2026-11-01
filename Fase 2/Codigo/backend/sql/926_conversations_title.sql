-- AgeCare — Ajuste de compatibilidad
-- 926_conversations_title.sql — Las conversaciones del asistente necesitan titulo
--
-- La pantalla del asistente lista las conversaciones anteriores por su titulo,
-- igual que cualquier aplicacion de chat con IA. conversations no tenia esa
-- columna, asi que la lista habria salido con todas las filas diciendo
-- 'Conversacion', que es el valor por defecto que la pantalla usa cuando el
-- campo no viene.
--
-- El titulo se arma con la primera pregunta de la conversacion. No se le pide
-- a la persona que lo escriba: nadie titula una conversacion antes de tenerla.
--
-- Solo aplica al asistente. El chat humano es uno solo por paciente y no se
-- lista, asi que ahi la columna queda en NULL.
--
-- NOTA sobre cuantas conversaciones hay. ux_conversations_assistant, definido
-- en 801_conversations.sql, deja UNA conversacion de asistente por paciente y
-- persona. La pantalla muestra una lista, pero esa lista va a tener siempre
-- un solo elemento: el hilo que esa persona mantiene sobre ese paciente.
-- No se toca esa restriccion aca. Si el equipo decide que una persona pueda
-- tener varios hilos sobre el mismo paciente, el cambio es quitar ese indice
-- unico, y es una decision de producto que no corresponde tomar de paso.

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS title varchar(120);

ALTER TABLE conversations DROP CONSTRAINT IF EXISTS ck_conversations_title;

ALTER TABLE conversations ADD CONSTRAINT ck_conversations_title CHECK (
    title IS NULL OR btrim(title) <> ''
);

-- La pantalla pide las conversaciones de una persona sobre un paciente,
-- ordenadas por la ultima actividad.
CREATE INDEX IF NOT EXISTS ix_conversations_asistente
    ON conversations (patient_id, user_id, last_message_at DESC)
    WHERE type = 'assistant';

COMMENT ON COLUMN conversations.title IS
    'Titulo de la conversacion con el asistente, derivado de la primera pregunta. NULL en el chat humano, que es uno solo por paciente y no se lista.';

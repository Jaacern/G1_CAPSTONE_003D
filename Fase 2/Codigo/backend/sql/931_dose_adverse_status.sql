-- AgeCare — Hito 2: alertas accionables de la cuidadora
-- 931_dose_adverse_status.sql — Desenlace de la dosis + evento adverso
--
-- Problema que resuelve (DEF-003):
--   La cuidadora solo podia marcar una dosis como tomada, pospuesta u omitida.
--   La vida real no cabe en esa lista: la vomito, la escupio, se atraganto,
--   estaba dormida, no habia stock, el paciente se nego... Cerrar un estado
--   por cada anecdota es el mismo error de siempre.
--
--   Solucion de DOS EJES, no un estado por caso:
--     1) status  : desenlace acotado y estable. Se agrega un unico estado nuevo
--                  'adverse' = se administro pero hubo un problema (el farmaco
--                  entro al cuerpo pero no quedo bien). Es clinicamente distinto
--                  de 'missed'/'skipped' (no se administro) y de 'taken' (ok).
--     2) reason  : nota LIBRE donde la cuidadora escribe lo que de verdad paso
--                  ("la vomito a los 10 min", "la escupio"). Ya existe.
--
--   Que gatilla alerta lo decide el desenlace, no el texto: 'adverse' siempre
--   avisa; 'skipped'/'missed' avisan segun las reglas de dosis omitida. Asi,
--   cualquier caso nuevo del mundo real se registra sin tocar el esquema.

ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_status;
ALTER TABLE scheduled_doses ADD CONSTRAINT ck_scheduled_doses_status CHECK (
    status IN ('pending', 'taken', 'skipped', 'postponed', 'missed', 'adverse')
);

-- 'adverse' exige motivo (que paso), igual que skipped (RF-29 extendido).
ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_skip_reason;
ALTER TABLE scheduled_doses ADD CONSTRAINT ck_scheduled_doses_skip_reason CHECK (
    status NOT IN ('skipped', 'adverse') OR reason IS NOT NULL
);

-- Confirmar/descartar/adverse: quien y cuando van siempre juntos.
ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_logged_status;
ALTER TABLE scheduled_doses ADD CONSTRAINT ck_scheduled_doses_logged_status CHECK (
    status NOT IN ('taken', 'skipped', 'adverse') OR logged_at IS NOT NULL
);

-- 'adverse' implica que se administro: debe llevar administered_at, como taken.
ALTER TABLE scheduled_doses DROP CONSTRAINT IF EXISTS ck_scheduled_doses_administered;
ALTER TABLE scheduled_doses ADD CONSTRAINT ck_scheduled_doses_administered CHECK (
    status NOT IN ('taken', 'adverse') OR administered_at IS NOT NULL
);

COMMENT ON COLUMN scheduled_doses.status IS
    'pending | taken | skipped | postponed | missed | adverse. adverse = se administro pero hubo un problema (vomito, rechazo tardio, reaccion...); el detalle va en reason. Cuenta como no retenida en la adherencia y gatilla alerta (DEF-003).';
COMMENT ON COLUMN scheduled_doses.reason IS
    'Motivo libre. Obligatorio en skipped y adverse. Es donde la cuidadora describe lo que realmente paso, sin una lista cerrada.';

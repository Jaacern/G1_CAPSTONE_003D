-- AgeCare — Bloque 3: Medicación
-- 312_prn_uses.sql — Registro de cada uso de una indicación SOS
--
-- POR QUÉ
--   Una indicación SOS (treatment_items.is_prn) no genera dosis en la agenda,
--   así que su uso no quedaba en ningún lado: el médico no podía saber cuántas
--   veces se usó el bromuro de ipratropio en la semana ni a qué hora. Cada uso
--   se registra aquí con la hora real, el motivo y quién lo declaró.
--
-- Correcciones 2FN aplicadas (mismo criterio que scheduled_doses):
--   · patient_id NO se guarda: dependería de treatment_item_id (vía treatments)
--     y no de la PK. Las consultas por paciente hacen JOIN.
--   · La dosis tampoco se copia: es la de la indicación (treatment_items).
--   · Tabla append-only, como vital_readings: un uso no se edita. Por eso no
--     tiene updated_at ni trigger.

CREATE TABLE treatment_item_prn_uses (
    id                uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_item_id uuid         NOT NULL,
    -- Cuándo se dio realmente (hecho clínico). Puede ser algo antes de logged_at.
    administered_at   timestamptz  NOT NULL,
    reason            varchar(200) NOT NULL,
    -- true si se registró antes de cumplirse el intervalo mínimo, con confirmación.
    overrode_interval boolean      NOT NULL DEFAULT false,
    logged_by         uuid         NOT NULL,
    logged_at         timestamptz  NOT NULL DEFAULT now(),
    created_at        timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_prn_uses_item
        FOREIGN KEY (treatment_item_id) REFERENCES treatment_items(id) ON DELETE RESTRICT,
    CONSTRAINT fk_prn_uses_user
        FOREIGN KEY (logged_by) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT ck_prn_uses_reason
        CHECK (char_length(btrim(reason)) >= 3),
    -- No se registra un uso en el futuro (margen de 5 min por relojes).
    CONSTRAINT ck_prn_uses_order
        CHECK (administered_at <= logged_at + interval '5 minutes')
);

-- Último uso y conteo de 24 h por indicación: la consulta de cada registro.
CREATE INDEX ix_prn_uses_item_time
    ON treatment_item_prn_uses (treatment_item_id, administered_at DESC);

COMMENT ON TABLE  treatment_item_prn_uses IS
    'Cada uso de una indicación SOS (is_prn): hora real, motivo y quién lo registró. Append-only. Sin patient_id (2FN): se llega por treatment_items → treatments.';
COMMENT ON COLUMN treatment_item_prn_uses.administered_at IS
    'Momento real en que se dio la dosis SOS. Distinto de logged_at (cuándo se anotó).';
COMMENT ON COLUMN treatment_item_prn_uses.reason IS
    'Por qué se dio (ej. "crisis de disnea"). Obligatorio: es lo que el médico necesita para ajustar el tratamiento.';
COMMENT ON COLUMN treatment_item_prn_uses.overrode_interval IS
    'true si se dio antes del intervalo mínimo de la indicación, tras confirmarlo.';

-- ============================================================================
-- BLOQUE 6 · Auditoria y administracion
-- 602_device_link_codes.sql — Codigos de vinculacion de dispositivos
-- Requisitos: RF-68 (vincular el dispositivo del adulto mayor por codigo,
--             sin credenciales)
-- ----------------------------------------------------------------------------
-- El adulto mayor no tiene cuenta ni contrasena. La cuidadora o el familiar
-- genera un codigo corto, lo escribe en la tablet del adulto mayor, y esa
-- tablet queda vinculada al paciente. El codigo es el unico momento de
-- autenticacion, y despues de usarse no sirve mas.
--
-- Solo se guarda code_hash, nunca el codigo en claro. Un codigo de 6 digitos
-- es corto por diseno (hay que dictarlo en voz alta), asi que la defensa esta
-- en otra parte: vence rapido (expires_at) y se bloquea a los 5 intentos
-- fallidos (ck_device_link_codes_attempts). Sin esos dos limites, 6 digitos
-- se rompen por fuerza bruta en minutos.
--
-- No hay FK hacia elder_devices a proposito: el dispositivo apunta al codigo
-- que lo creo (603_elder_devices.link_code_id) y no al contrario. Asi se evita
-- una dependencia circular entre las dos tablas.
-- ============================================================================

CREATE TABLE device_link_codes (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id  uuid        NOT NULL,
    code_hash   varchar(64) NOT NULL,
    created_by  uuid        NOT NULL,
    expires_at  timestamptz NOT NULL,
    attempts    smallint    NOT NULL DEFAULT 0,
    used_at     timestamptz,
    revoked_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_device_link_codes_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_device_link_codes_created_by
        FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT uq_device_link_codes_hash UNIQUE (code_hash),

    -- Bloqueo por fuerza bruta: 5 intentos y el codigo muere.
    CONSTRAINT ck_device_link_codes_attempts CHECK (attempts BETWEEN 0 AND 5),
    -- Un codigo de un solo uso no puede estar usado y revocado a la vez.
    CONSTRAINT ck_device_link_codes_estado CHECK (
        used_at IS NULL OR revoked_at IS NULL
    ),
    CONSTRAINT ck_device_link_codes_vigencia CHECK (expires_at > created_at)
);

-- Codigos vigentes de un paciente: lo que consulta la pantalla de vinculacion.
CREATE INDEX ix_device_link_codes_vigentes
    ON device_link_codes (patient_id, expires_at DESC)
    WHERE used_at IS NULL AND revoked_at IS NULL;

COMMENT ON TABLE  device_link_codes IS 'Codigos de un solo uso para vincular el dispositivo del adulto mayor sin credenciales. Vencen y se bloquean por intentos fallidos. RF-68.';
COMMENT ON COLUMN device_link_codes.id IS 'Identificador del codigo.';
COMMENT ON COLUMN device_link_codes.patient_id IS 'Paciente al que quedara vinculado el dispositivo.';
COMMENT ON COLUMN device_link_codes.code_hash IS 'Hash del codigo. El codigo en claro no se guarda nunca.';
COMMENT ON COLUMN device_link_codes.created_by IS 'Usuario que genero el codigo.';
COMMENT ON COLUMN device_link_codes.expires_at IS 'Vencimiento del codigo. Corto por diseno, porque el codigo es corto.';
COMMENT ON COLUMN device_link_codes.attempts IS 'Intentos fallidos acumulados. Al llegar a 5 el codigo queda inservible.';
COMMENT ON COLUMN device_link_codes.used_at IS 'Momento en que el codigo se canjeo por un dispositivo vinculado.';
COMMENT ON COLUMN device_link_codes.revoked_at IS 'Momento en que se anulo el codigo antes de usarse.';
COMMENT ON COLUMN device_link_codes.created_at IS 'Fecha de creacion del registro.';

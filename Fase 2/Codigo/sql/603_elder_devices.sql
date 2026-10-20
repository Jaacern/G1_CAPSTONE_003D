-- ============================================================================
-- BLOQUE 6 · Auditoria y administracion
-- 603_elder_devices.sql — Dispositivos del adulto mayor
-- Requisitos: RF-68 (vinculacion por codigo sin credenciales),
--             RF-60 a RF-67 (la vista del adulto mayor corre en estos equipos)
-- ----------------------------------------------------------------------------
-- Esta es la tabla que explica por que el adulto mayor no esta en users: la
-- credencial no la tiene una persona, la tiene un DISPOSITIVO. El equipo
-- guarda session_token_hash y con eso opera; no hay correo ni contrasena que
-- el adulto mayor tenga que recordar. Si se pierde la tablet, se marca
-- unlinked_at y ese token deja de servir, sin tocar ninguna cuenta.
--
-- Es la misma idea que push_devices, pero push_devices pertenece a un usuario
-- y este pertenece a un paciente. No se pueden unir sin romper eso.
--
-- Se permite mas de un dispositivo por paciente (la tablet del living y otra
-- en la pieza). A diferencia del wearable, que RF-15 limita a uno activo.
-- ============================================================================

CREATE TABLE elder_devices (
    id                 uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id         uuid         NOT NULL,
    link_code_id       uuid         NOT NULL,
    device_label       varchar(60)  NOT NULL,
    platform           varchar(10)  NOT NULL,
    device_fingerprint varchar(128) NOT NULL,
    session_token_hash varchar(64)  NOT NULL,
    push_token         varchar(255),
    app_version        varchar(20),
    last_seen_at       timestamptz,
    unlinked_at        timestamptz,
    created_at         timestamptz  NOT NULL DEFAULT now(),
    updated_at         timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_elder_devices_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_elder_devices_link_code
        FOREIGN KEY (link_code_id) REFERENCES device_link_codes(id) ON DELETE RESTRICT,

    -- Un codigo vincula un solo dispositivo. Es de un solo uso.
    CONSTRAINT uq_elder_devices_link_code UNIQUE (link_code_id),
    CONSTRAINT uq_elder_devices_fingerprint UNIQUE (device_fingerprint),
    CONSTRAINT uq_elder_devices_session UNIQUE (session_token_hash),
    CONSTRAINT uq_elder_devices_push UNIQUE (push_token),

    CONSTRAINT ck_elder_devices_platform CHECK (
        platform IN ('android','ios','web')
    ),
    CONSTRAINT ck_elder_devices_label CHECK (btrim(device_label) <> '')
);

-- Dispositivos activos de un paciente.
CREATE INDEX ix_elder_devices_patient_activos
    ON elder_devices (patient_id, last_seen_at DESC)
    WHERE unlinked_at IS NULL;

COMMENT ON TABLE  elder_devices IS 'Dispositivos vinculados al adulto mayor. La credencial vive en el equipo, no en una cuenta de persona, que es por lo que el adulto mayor no figura en users. RF-68.';
COMMENT ON COLUMN elder_devices.id IS 'Identificador del dispositivo.';
COMMENT ON COLUMN elder_devices.patient_id IS 'Paciente al que pertenece el dispositivo.';
COMMENT ON COLUMN elder_devices.link_code_id IS 'Codigo de vinculacion con que se dio de alta este dispositivo.';
COMMENT ON COLUMN elder_devices.device_label IS 'Nombre con que la familia reconoce el equipo, por ejemplo tablet del living.';
COMMENT ON COLUMN elder_devices.platform IS 'Plataforma del dispositivo: android, ios o web.';
COMMENT ON COLUMN elder_devices.device_fingerprint IS 'Huella del equipo. Impide reutilizar la sesion en otro dispositivo.';
COMMENT ON COLUMN elder_devices.session_token_hash IS 'Hash del token de sesion del dispositivo. Reemplaza al par correo y contrasena.';
COMMENT ON COLUMN elder_devices.push_token IS 'Token de notificaciones del dispositivo, si las recibe.';
COMMENT ON COLUMN elder_devices.app_version IS 'Version de la aplicacion instalada. Sirve para soporte.';
COMMENT ON COLUMN elder_devices.last_seen_at IS 'Ultima vez que el dispositivo se comunico con el servidor.';
COMMENT ON COLUMN elder_devices.unlinked_at IS 'Momento en que se desvinculo. La fila se conserva y el token deja de servir.';
COMMENT ON COLUMN elder_devices.created_at IS 'Fecha de creacion del registro.';
COMMENT ON COLUMN elder_devices.updated_at IS 'Fecha de la ultima modificacion del registro.';

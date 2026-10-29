-- AgeCare — Bloque 9: Marketplace

CREATE TABLE contact_requests (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id      uuid          NOT NULL,
    requester_id    uuid          NOT NULL,
    patient_id      uuid,
    message         varchar(1000) NOT NULL,
    status          varchar(12)   NOT NULL DEFAULT 'pending',
    channel         varchar(12),
    responded_at    timestamptz,
    decline_reason  varchar(200),
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT fk_contact_requests_profile
        FOREIGN KEY (profile_id) REFERENCES caregiver_profiles(id) ON DELETE RESTRICT,
    CONSTRAINT fk_contact_requests_requester
        FOREIGN KEY (requester_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_contact_requests_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,

    CONSTRAINT ck_contact_requests_message CHECK (btrim(message) <> ''),
    CONSTRAINT ck_contact_requests_status CHECK (
        status IN ('pending','accepted','declined','expired','withdrawn')
    ),
    CONSTRAINT ck_contact_requests_channel CHECK (
        channel IS NULL OR channel IN ('phone','email','chat')
    ),
    -- Una solicitud pendiente todavía no tiene respuesta; una resuelta sí.
    CONSTRAINT ck_contact_requests_respuesta CHECK (
        (status = 'pending' AND responded_at IS NULL)
     OR (status <> 'pending' AND responded_at IS NOT NULL)
    ),
    -- El canal se entrega solo cuando la solicitud fue aceptada. Es la parte de
    -- RF-77 que importa, no se filtra un medio de contacto sin aceptación.
    CONSTRAINT ck_contact_requests_canal_si_acepta CHECK (
        (status = 'accepted' AND channel IS NOT NULL)
     OR (status <> 'accepted' AND channel IS NULL)
    ),
    CONSTRAINT ck_contact_requests_rechazo CHECK (
        status = 'declined' OR decline_reason IS NULL
    )
);

-- Una misma persona no puede tener dos solicitudes abiertas con la misma
-- cuidadora. Puede volver a escribirle una vez que la primera se resolvió.
CREATE UNIQUE INDEX ux_contact_requests_pendiente
    ON contact_requests (profile_id, requester_id)
    WHERE status = 'pending';

-- Bandeja de la cuidadora.
CREATE INDEX ix_contact_requests_perfil
    ON contact_requests (profile_id, created_at DESC);

-- Solicitudes que envió un familiar.
CREATE INDEX ix_contact_requests_solicitante
    ON contact_requests (requester_id, created_at DESC);

CREATE TRIGGER tg_contact_requests_updated_at
    BEFORE UPDATE ON contact_requests
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  contact_requests IS
    'Solicitudes de contacto que un familiar envía a una cuidadora del marketplace, con su estado y el canal entregado al aceptar. RF-77.';
COMMENT ON COLUMN contact_requests.id IS
    'Identificador de la solicitud.';
COMMENT ON COLUMN contact_requests.profile_id IS
    'Cuidadora a la que se contacta.';
COMMENT ON COLUMN contact_requests.requester_id IS
    'Usuario que envía la solicitud.';
COMMENT ON COLUMN contact_requests.patient_id IS
    'Paciente para el que se busca cuidado. Opcional, porque se puede buscar antes de crear el expediente.';
COMMENT ON COLUMN contact_requests.message IS
    'Mensaje inicial del familiar.';
COMMENT ON COLUMN contact_requests.status IS
    'Estado de la solicitud: pending, accepted, declined, expired o withdrawn.';
COMMENT ON COLUMN contact_requests.channel IS
    'Canal entregado al aceptar: phone, email o chat. Nulo mientras no haya aceptación.';
COMMENT ON COLUMN contact_requests.responded_at IS
    'Momento en que la solicitud dejó de estar pendiente.';
COMMENT ON COLUMN contact_requests.decline_reason IS
    'Motivo del rechazo, cuando la cuidadora decide no aceptar.';
COMMENT ON COLUMN contact_requests.created_at IS
    'Fecha de creación del registro.';
COMMENT ON COLUMN contact_requests.updated_at IS
    'Fecha de la última modificación del registro.';

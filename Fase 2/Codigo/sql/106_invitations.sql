-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 6 de 6: invitations

CREATE TABLE invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid NOT NULL,
    email varchar(320) NOT NULL,
    role varchar(10)  NOT NULL,
    token_hash varchar(64)  NOT NULL,
    invited_by uuid NOT NULL,
    expires_at timestamptz NOT NULL,
    accepted_at timestamptz,
    accepted_by uuid,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_invitations_patient
    FOREIGN KEY (patient_id)  REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_invitations_invited_by
    FOREIGN KEY (invited_by)  REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT fk_invitations_accepted_by
    FOREIGN KEY (accepted_by) REFERENCES users(id) ON DELETE SET NULL,
CONSTRAINT ck_invitations_role
    CHECK (role IN ('family','caregiver','doctor','elder')),
CONSTRAINT ck_invitations_expires
    CHECK (expires_at > created_at),
CONSTRAINT ck_invitations_accepted_pair
    CHECK ((accepted_at IS NULL) = (accepted_by IS NULL)),
CONSTRAINT ck_invitations_not_both
    CHECK (NOT (accepted_at IS NOT NULL AND revoked_at IS NOT NULL))
);

-- Búsqueda al aceptar la invitación.
CREATE UNIQUE INDEX ux_invitations_token
    ON invitations (token_hash);

-- Una sola invitación viva por correo y paciente.
-- Reenviar actualiza la fila existente, no crea otra.
CREATE UNIQUE INDEX ux_invitations_pending
    ON invitations (patient_id, lower(email))
    WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- Listar las invitaciones de un paciente (endpoint 4.7).
CREATE INDEX ix_invitations_patient
    ON invitations (patient_id);

CREATE TRIGGER tg_invitations_updated_at
    BEFORE UPDATE ON invitations
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  invitations IS
    'Invitaciones al círculo de cuidado. Se invita a un CORREO, no a un usuario: el invitado puede no tener cuenta todavía (endpoints 4.6 y 3.1).';
COMMENT ON COLUMN invitations.email IS
    'Correo del invitado. Sin clave foránea a users porque puede no existir aún. La unicidad ignora mayúsculas (ver ux_invitations_pending).';
COMMENT ON COLUMN invitations.token_hash IS
    'SHA-256 del token de invitación. Nunca en claro: ese token da acceso a un expediente clínico.';
COMMENT ON COLUMN invitations.invited_by IS
    'Quién envió la invitación. Normalmente el familiar administrador.';
COMMENT ON COLUMN invitations.expires_at IS
    'Vencimiento. 7 días desde el envío, según el ticket AGE-202.';
COMMENT ON COLUMN invitations.accepted_by IS
    'Usuario que aceptó. ON DELETE SET NULL: si borra su cuenta, la invitación sigue siendo parte de la historia del paciente.';
COMMENT ON COLUMN invitations.revoked_at IS
    'Invitación anulada por el administrador antes de ser aceptada (ticket AGE-207).';

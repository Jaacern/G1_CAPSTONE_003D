-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 5 de 6: patient_members

CREATE TABLE patient_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid NOT NULL,
    user_id    uuid NOT NULL,
    role varchar(10) NOT NULL,
    is_owner boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    removed_at timestamptz,

CONSTRAINT fk_patient_members_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_patient_members_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT uq_patient_members_pair
    UNIQUE (patient_id, user_id),
CONSTRAINT ck_patient_members_role
    CHECK (role IN ('family','caregiver','doctor','elder')),
CONSTRAINT ck_patient_members_owner_is_family
    CHECK (NOT is_owner OR role = 'family')
);

-- Como máximo un administrador por paciente.
-- No puede garantizar que haya al menos uno: eso lo cuida la aplicación.
CREATE UNIQUE INDEX ux_patient_members_owner
    ON patient_members (patient_id) WHERE is_owner;

-- "¿Qué pacientes puedo ver?"
-- de toda la plataforma: se ejecuta antes que casi cualquier otra cosa.
CREATE INDEX ix_patient_members_user
    ON patient_members (user_id) WHERE removed_at IS NULL;

CREATE TRIGGER tg_patient_members_updated_at
    BEFORE UPDATE ON patient_members
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  patient_members IS
    'Vínculo entre usuarios y pacientes, con el rol de cada uno. Es el centro del control de acceso: ninguna consulta al expediente se ejecuta sin verificarla primero.';
COMMENT ON COLUMN patient_members.role IS
    'Rol DE LA RELACIÓN, no de la persona: family | caregiver | doctor | elder. El mismo usuario puede tener roles distintos sobre pacientes distintos.';
COMMENT ON COLUMN patient_members.is_owner IS
    'Familiar administrador del paciente. Lo crea el endpoint 4.1 y no puede ser eliminado (endpoint 4.8). Solo un rol family puede serlo.';
COMMENT ON COLUMN patient_members.removed_at IS
    'Baja del círculo de cuidado. Se conserva la fila porque el endpoint 14.4 exige saber quién estuvo alguna vez en el círculo para validar las reseñas.';

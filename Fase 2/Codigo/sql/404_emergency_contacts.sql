-- Tabla 4 de 5: emergency_contacts
CREATE TABLE emergency_contacts (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
-- 1FN y coherencia con users/patients: nombre y apellido son atributos distintos.
-- full_name queda como columna GENERATED para presentación y compatibilidad.
first_name varchar(60) NOT NULL,
last_name  varchar(60) NOT NULL,
full_name  varchar(121) GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
relationship  varchar(40),
phone varchar(16)  NOT NULL,
escalation_order smallint NOT NULL DEFAULT 1,
notes varchar(200),
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),
deleted_at timestamptz,

CONSTRAINT fk_emergency_contacts_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT ck_emergency_contacts_first_name
    CHECK (char_length(first_name) >= 1),
CONSTRAINT ck_emergency_contacts_last_name
    CHECK (char_length(last_name) >= 1),
CONSTRAINT ck_emergency_contacts_order
    CHECK (escalation_order BETWEEN 1 AND 10),
CONSTRAINT ck_emergency_contacts_phone
    CHECK (phone ~ '^\+[0-9]{8,15}$')
);

-- Dos contactos no pueden tener la misma prioridad para un paciente.
CREATE UNIQUE INDEX ux_emergency_contacts_order
    ON emergency_contacts (patient_id, escalation_order)
    WHERE deleted_at IS NULL;

CREATE TRIGGER tg_emergency_contacts_updated_at
    BEFORE UPDATE ON emergency_contacts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  emergency_contacts IS
    'Contactos de emergencia del paciente, en orden de escalamiento. No está en el Anexo A: se agrega porque el endpoint 9.6 debe devolver estos teléfonos y el RF-52 exige escalar a los siguientes cuando nadie atiende.';
COMMENT ON COLUMN emergency_contacts.escalation_order IS
    'Prioridad de aviso: 1 primero. Sin este orden, "los siguientes contactos" del RF-52 no se puede implementar.';

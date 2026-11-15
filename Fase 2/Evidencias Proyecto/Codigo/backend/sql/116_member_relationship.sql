-- AgeCare — Bloque 1: Identidad y acceso
-- 116_member_relationship.sql — Parentesco de los miembros familiares (Fase 6)
--
-- POR QUÉ (decisión del usuario, docs/DECISIONES_ABIERTAS_FICHA.md punto 4)
--   En la ficha debe verse, por cada familiar, su PARENTESCO con el paciente
--   (hijo, hija, hermano, hermana, cónyuge...). "Los hijos" no son un número
--   suelto: son miembros del grupo con parentesco. El teléfono sale del perfil
--   del usuario (una sola fuente) y "cuál es el de emergencia" ya se resuelve en
--   emergency_contacts (punto 1). Aquí solo se agrega el parentesco.
--
--   Se agrega como columna en patient_members (ya tiene role y profession). No es
--   lo mismo que profession (clínico): un familiar puede ser "hija" (parentesco)
--   sin profesión de salud. Lista cerrada razonable, NULL permitido (un médico
--   contratado no tiene parentesco).

ALTER TABLE patient_members
    ADD COLUMN IF NOT EXISTS relationship varchar(20);

ALTER TABLE patient_members DROP CONSTRAINT IF EXISTS ck_patient_members_relationship;
ALTER TABLE patient_members ADD CONSTRAINT ck_patient_members_relationship CHECK (
    relationship IS NULL OR relationship IN
        ('hijo', 'hija', 'conyuge', 'hermano', 'hermana', 'nieto', 'nieta',
         'sobrino', 'sobrina', 'yerno', 'nuera', 'cuidador', 'otro')
);

COMMENT ON COLUMN patient_members.relationship IS
    'Parentesco del miembro con el paciente (hijo, hija, cónyuge, hermano...). NULL para quienes no son familia (ej. médico contratado). Distinto de profession (rol clínico).';

-- La invitación también lleva el parentesco, para copiarlo al aceptar (igual que
-- se hace con profession desde la Fase 5).
ALTER TABLE invitations
    ADD COLUMN IF NOT EXISTS relationship varchar(20);

ALTER TABLE invitations DROP CONSTRAINT IF EXISTS ck_invitations_relationship;
ALTER TABLE invitations ADD CONSTRAINT ck_invitations_relationship CHECK (
    relationship IS NULL OR relationship IN
        ('hijo', 'hija', 'conyuge', 'hermano', 'hermana', 'nieto', 'nieta',
         'sobrino', 'sobrina', 'yerno', 'nuera', 'cuidador', 'otro')
);

COMMENT ON COLUMN invitations.relationship IS
    'Parentesco propuesto para el invitado. Se copia a patient_members.relationship al aceptar.';

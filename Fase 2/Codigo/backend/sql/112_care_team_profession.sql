-- AgeCare — Bloque 1: Identidad y acceso
-- 112_care_team_profession.sql — Profesión del miembro del equipo de salud (Fase 5)
--
-- POR QUÉ (caso real)
--   La ficha de Rosa lista un equipo tratante amplio: médico general,
--   traumatólogo, kinesiólogo, enfermera, podóloga, cuidadora. El modelo de
--   permisos (patient_members.role) tiene 4 roles: family/caregiver/doctor/elder,
--   y role es varchar(10). No conviene inflar el RBAC con una decena de
--   profesiones (complica permisos y no caben en 10 chars).
--
--   Solución: 'role' sigue siendo el PERMISO (doctor cubre a los profesionales
--   de salud; caregiver a la cuidadora). Se agrega 'profession' como etiqueta
--   del rol clínico real, para mostrar el equipo como en la ficha. Así un
--   kinesiólogo entra con permiso 'doctor' y profesión 'kinesiologo'.

ALTER TABLE patient_members
    ADD COLUMN IF NOT EXISTS profession varchar(30);

ALTER TABLE patient_members DROP CONSTRAINT IF EXISTS ck_patient_members_profession;
ALTER TABLE patient_members ADD CONSTRAINT ck_patient_members_profession CHECK (
    profession IS NULL OR profession IN
        ('medico_general','medico_especialista','kinesiologo','enfermera',
         'podologa','nutricionista','fonoaudiologo','terapeuta_ocupacional',
         'psicologo','trabajador_social','cuidadora','familiar')
);

COMMENT ON COLUMN patient_members.profession IS
    'Rol clínico real del miembro (medico_general, kinesiologo, enfermera, podologa, ...). role sigue siendo el PERMISO (family/caregiver/doctor/elder); profession es la etiqueta del equipo tratante. NULL si no aplica.';

-- Las invitaciones también llevan la profesión, para asignarla al aceptar.
ALTER TABLE invitations
    ADD COLUMN IF NOT EXISTS profession varchar(30);

ALTER TABLE invitations DROP CONSTRAINT IF EXISTS ck_invitations_profession;
ALTER TABLE invitations ADD CONSTRAINT ck_invitations_profession CHECK (
    profession IS NULL OR profession IN
        ('medico_general','medico_especialista','kinesiologo','enfermera',
         'podologa','nutricionista','fonoaudiologo','terapeuta_ocupacional',
         'psicologo','trabajador_social','cuidadora','familiar')
);

COMMENT ON COLUMN invitations.profession IS
    'Profesión que tendrá el miembro al aceptar la invitación. Se copia a patient_members.profession.';

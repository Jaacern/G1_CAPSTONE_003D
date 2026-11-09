-- =====================================================================
-- AgeCare — Demo adicional: un círculo de cuidado con 3 pacientes
-- =====================================================================
-- Datos inventados para desarrollo (2026-11-09). Complementa 900_seed_dev.
--
-- Cuentas (contraseña en claro solo aquí, para probar en local):
--   familiar   marcela.rojas@agecare.cl    Marcela2026  (owner de los 3)
--   cuidadora  paulina.soto@cuidados.cl    Paulina2026  (caregiver de los 3)
--   medico     andres.fuentes@clinica.cl   Andres2026   (doctor de los 3)
--
-- Idempotente: todo lleva ON CONFLICT DO NOTHING, así que correrlo sobre
-- una base que ya tiene estos datos (p. ej. creados por la API) no falla
-- ni duplica nada.
-- =====================================================================

-- ---------------------------------------------------------------
-- 1. Usuarios del círculo
-- ---------------------------------------------------------------
INSERT INTO users (id, email, password_hash, first_name, last_name, phone, locale) VALUES
  ('85c14965-81ec-4037-8564-bb080cbf9da8',
   'marcela.rojas@agecare.cl',
   '$2b$12$rlWsorxzq5y.k7txRqetz.pqFLd3lfLrk.l7RdarDeqMJnHBzfynu',
   'Marcela', 'Rojas Fuentes', '+56911110001', 'es'),
  ('b985337d-0c2f-40f7-8a64-ec1df8973aaf',
   'paulina.soto@cuidados.cl',
   '$2b$12$Q5dQUz3hKduNWH81vLUnLuqRL1GVaW.ntkEFG82S6D.eRsCJxMMGC',
   'Paulina', 'Soto Vargas', '+56911110002', 'es'),
  ('4a3cfa1a-fdc5-4245-9935-9b902250d906',
   'andres.fuentes@clinica.cl',
   '$2b$12$OmA7jqgyOKpxOtTiqDc.MOgs0acUJFwGd934f7.7dZuDusXDFLiJK',
   'Andrés', 'Fuentes Lagos', '+56911110003', 'es')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------
-- 2. Pacientes
-- ---------------------------------------------------------------
INSERT INTO patients (id, first_name, last_name, birth_date, sex) VALUES
  ('b1cabd30-7448-4581-8600-48307fbc6a98',
   'Carmen Gloria', 'Álvarez Pérez', '1938-05-21', 'F'),
  ('1f9d33f9-7639-46c7-94bd-f6d93fdf8245',
   'Luis Alberto', 'Herrera Campos', '1941-11-03', 'M'),
  ('d983c076-5d00-4790-a070-8f7950b635de',
   'Teresa de Jesús', 'Morales Riquelme', '1945-02-14', 'F')
ON CONFLICT (id) DO NOTHING;

INSERT INTO patient_conditions (patient_id, condition) VALUES
  ('b1cabd30-7448-4581-8600-48307fbc6a98', 'hipertension'),
  ('b1cabd30-7448-4581-8600-48307fbc6a98', 'diabetes_tipo_2'),
  ('1f9d33f9-7639-46c7-94bd-f6d93fdf8245', 'hipertension'),
  ('d983c076-5d00-4790-a070-8f7950b635de', 'diabetes_tipo_2')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------
-- 3. Círculo de cuidado: la familiar dueña, cuidadora y médico en los 3
-- ---------------------------------------------------------------
INSERT INTO patient_members (patient_id, user_id, role, is_owner, profession) VALUES
  ('b1cabd30-7448-4581-8600-48307fbc6a98', '85c14965-81ec-4037-8564-bb080cbf9da8', 'family',    true,  NULL),
  ('1f9d33f9-7639-46c7-94bd-f6d93fdf8245', '85c14965-81ec-4037-8564-bb080cbf9da8', 'family',    true,  NULL),
  ('d983c076-5d00-4790-a070-8f7950b635de', '85c14965-81ec-4037-8564-bb080cbf9da8', 'family',    true,  NULL),
  ('b1cabd30-7448-4581-8600-48307fbc6a98', 'b985337d-0c2f-40f7-8a64-ec1df8973aaf', 'caregiver', false, 'cuidadora'),
  ('1f9d33f9-7639-46c7-94bd-f6d93fdf8245', 'b985337d-0c2f-40f7-8a64-ec1df8973aaf', 'caregiver', false, 'cuidadora'),
  ('d983c076-5d00-4790-a070-8f7950b635de', 'b985337d-0c2f-40f7-8a64-ec1df8973aaf', 'caregiver', false, 'cuidadora'),
  ('b1cabd30-7448-4581-8600-48307fbc6a98', '4a3cfa1a-fdc5-4245-9935-9b902250d906', 'doctor',    false, 'medico_general'),
  ('1f9d33f9-7639-46c7-94bd-f6d93fdf8245', '4a3cfa1a-fdc5-4245-9935-9b902250d906', 'doctor',    false, 'medico_general'),
  ('d983c076-5d00-4790-a070-8f7950b635de', '4a3cfa1a-fdc5-4245-9935-9b902250d906', 'doctor',    false, 'medico_general')
ON CONFLICT (patient_id, user_id) DO NOTHING;

-- ---------------------------------------------------------------
-- 4. Umbrales de partida (los mismos que deja la API al crear el paciente)
-- ---------------------------------------------------------------
INSERT INTO vital_thresholds (patient_id, type, min_value, max_value, updated_by) VALUES
  ('b1cabd30-7448-4581-8600-48307fbc6a98', 'heart_rate', 45, 115, '85c14965-81ec-4037-8564-bb080cbf9da8'),
  ('b1cabd30-7448-4581-8600-48307fbc6a98', 'spo2',       92, NULL, '85c14965-81ec-4037-8564-bb080cbf9da8'),
  ('1f9d33f9-7639-46c7-94bd-f6d93fdf8245', 'heart_rate', 45, 115, '85c14965-81ec-4037-8564-bb080cbf9da8'),
  ('1f9d33f9-7639-46c7-94bd-f6d93fdf8245', 'spo2',       92, NULL, '85c14965-81ec-4037-8564-bb080cbf9da8'),
  ('d983c076-5d00-4790-a070-8f7950b635de', 'heart_rate', 50, 110, '85c14965-81ec-4037-8564-bb080cbf9da8'),
  ('d983c076-5d00-4790-a070-8f7950b635de', 'spo2',       92, NULL, '85c14965-81ec-4037-8564-bb080cbf9da8')
ON CONFLICT DO NOTHING;
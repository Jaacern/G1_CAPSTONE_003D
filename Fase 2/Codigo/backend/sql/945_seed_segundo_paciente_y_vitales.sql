-- AgeCare — Datos de demostracion (SOLO DESARROLLO)
-- 945_seed_segundo_paciente_y_vitales.sql
-- MIGRACION IDEMPOTENTE
-- SEMILLA
-- Datos de ejemplo, no un cambio de esquema. Por eso no lleva revert
-- en sql/revertir/: deshacerla seria borrar datos de demostracion, que
-- es otra cosa que deshacer una migracion (RNF-24).
--
-- POR QUE
--   1. El seed tenia un solo paciente, asi que nada que dependa de tener
--      varios se podia probar: el selector de paciente de Salud, la lista del
--      medico ordenada por criticidad, el filtro "solo este paciente" de
--      alertas. Se agrega a Luis Alberto Fuentes Rojas, esposo de Elena y
--      padre de la familiar (E-FAM-03 de docs/QA_ESCENARIOS_REALES_POR_ROL.md),
--      con el mismo circulo: la familiar, la cuidadora y la doctora Soto.
--   2. Ningun paciente tenia presion arterial, temperatura ni glucosa: las
--      tres tarjetas de Salud salian "Sin datos aun". Se agregan con sus
--      rangos, para Elena (hipertensa y diabetica) y para Luis.
--
-- REPETIBLE
--   Ids fijos con ON CONFLICT para lo que es una fila, y "solo si no hay
--   ninguna lectura de ese tipo" para las series de signos vitales, que se
--   generan contra now() y repetidas se duplicarian.

-- ---------------------------------------------------------------------
-- 1. Luis Alberto Fuentes Rojas
-- ---------------------------------------------------------------------
-- 6.234.567 lleva digito verificador 5.
INSERT INTO patients (id, first_name, second_name, last_name, second_last_name,
                      rut_number, rut_dv, birth_date, sex, address,
                      marital_status, insurance, rcv_level, complexity, priority)
VALUES ('33333333-3333-4333-8333-333333333334',
        'Luis', 'Alberto', 'Fuentes', 'Rojas',
        6234567, '5', '1940-08-21', 'M',
        'Pasaje Los Lirios 456, Concepción',
        'viudo', 'fonasa', 'alto', 'alta', 'alta')
ON CONFLICT (id) DO NOTHING;

INSERT INTO patient_conditions (patient_id, condition) VALUES
  ('33333333-3333-4333-8333-333333333334', 'epoc'),
  ('33333333-3333-4333-8333-333333333334', 'insuficiencia_cardiaca'),
  ('33333333-3333-4333-8333-333333333334', 'hipertension')
ON CONFLICT DO NOTHING;

INSERT INTO patient_allergies (patient_id, substance, category, severity, reaction, source)
SELECT '33333333-3333-4333-8333-333333333334', 'aspirina', 'medicamento',
       'severa', 'Broncoespasmo', 'reportada'
WHERE NOT EXISTS (SELECT 1 FROM patient_allergies
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334'
                     AND substance = 'aspirina' AND deleted_at IS NULL);

-- Circulo de cuidado: su hija administra el perfil.
INSERT INTO patient_members (patient_id, user_id, role, is_owner, relationship)
VALUES ('33333333-3333-4333-8333-333333333334',
        '11111111-1111-4111-8111-111111111111', 'family', true, 'hija'),
       ('33333333-3333-4333-8333-333333333334',
        '22222222-2222-4222-8222-222222222222', 'caregiver', false, NULL)
ON CONFLICT (patient_id, user_id) DO NOTHING;

INSERT INTO patient_members (patient_id, user_id, role, is_owner, profession)
SELECT '33333333-3333-4333-8333-333333333334', u.id, 'doctor', false, 'medico_general'
  FROM users u WHERE lower(u.email) = 'doctora@agecare.cl'
ON CONFLICT (patient_id, user_id) DO NOTHING;

INSERT INTO emergency_contacts (patient_id, member_user_id, notes)
SELECT '33333333-3333-4333-8333-333333333334',
       '11111111-1111-4111-8111-111111111111', 'Hija, administra el perfil'
WHERE NOT EXISTS (SELECT 1 FROM emergency_contacts
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334'
                     AND member_user_id = '11111111-1111-4111-8111-111111111111'
                     AND deleted_at IS NULL);

INSERT INTO wearables (id, patient_id, provider, serial_number, model, battery_pct, last_sync_at)
VALUES ('44444444-4444-4444-8444-444444444445',
        '33333333-3333-4333-8333-333333333334',
        'simulator', 'SIM-000002', 'AgeCare Band v1', 41, now() - interval '9 minutes')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. Rangos de signos vitales
-- ---------------------------------------------------------------------
-- Luis: con EPOC la saturacion de base es mas baja (minimo 88). Presion,
-- temperatura y glucosa con rangos de adulto mayor. En presion el rango es
-- de la sistolica.
INSERT INTO vital_thresholds (patient_id, type, min_value, max_value)
SELECT p, t, mn, mx FROM (VALUES
    ('33333333-3333-4333-8333-333333333334'::uuid, 'heart_rate',     55::numeric, 105::numeric),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'spo2',           88, NULL),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'blood_pressure', 90, 150),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'temperature',    35.5, 37.8),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'glucose',        70, 180),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'blood_pressure', 90, 140),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'temperature',    35.5, 37.8),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'glucose',        70, 180)
) AS v(p, t, mn, mx)
WHERE NOT EXISTS (SELECT 1 FROM vital_thresholds th
                   WHERE th.patient_id = v.p AND th.type = v.t AND th.deleted_at IS NULL);

-- ---------------------------------------------------------------------
-- 3. Signos vitales de Luis (30 dias)
-- ---------------------------------------------------------------------
INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT '33333333-3333-4333-8333-333333333334', 'heart_rate',
       ROUND((80 + 9 * sin(EXTRACT(epoch FROM ts) / 12600.0) + (random() * 8 - 4))::numeric, 2),
       ts, 'wearable', '{"origin":"simulator"}'::jsonb
FROM generate_series(now() - interval '30 days', now(), interval '1 hour') ts
WHERE NOT EXISTS (SELECT 1 FROM vital_readings
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334' AND type = 'heart_rate');

INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT '33333333-3333-4333-8333-333333333334', 'spo2',
       ROUND((92 + (random() * 3 - 1.5))::numeric, 2),
       ts, 'wearable', '{"origin":"simulator"}'::jsonb
FROM generate_series(now() - interval '30 days', now(), interval '2 hours') ts
WHERE NOT EXISTS (SELECT 1 FROM vital_readings
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334' AND type = 'spo2');

-- Desaturaciones puntuales: quedan bajo su minimo (88) y aparecen en el historial.
INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT '33333333-3333-4333-8333-333333333334', 'spo2', v, ts, 'wearable',
       '{"origin":"simulator"}'::jsonb
FROM (VALUES (86.5::numeric, now() - interval '9 days'  + interval '13 minutes'),
             (87.0,          now() - interval '2 days'  + interval '13 minutes'),
             (86.0,          now() - interval '50 minutes')) AS a(v, ts)
WHERE NOT EXISTS (SELECT 1 FROM vital_readings
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334'
                     AND type = 'spo2' AND value < 88);

INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT '33333333-3333-4333-8333-333333333334', 'steps',
       ROUND((600 + random() * 1800)::numeric, 2),
       date_trunc('day', ts) + interval '22 hours', 'wearable', '{"origin":"simulator"}'::jsonb
FROM generate_series(now() - interval '30 days', now() - interval '1 day', interval '1 day') ts
WHERE NOT EXISTS (SELECT 1 FROM vital_readings
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334' AND type = 'steps');

INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT '33333333-3333-4333-8333-333333333334', 'sleep',
       ROUND((5 + random() * 2.5)::numeric, 2),
       date_trunc('day', ts) + interval '7 hours', 'wearable', '{"origin":"simulator"}'::jsonb
FROM generate_series(now() - interval '30 days', now() - interval '1 day', interval '1 day') ts
WHERE NOT EXISTS (SELECT 1 FROM vital_readings
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334' AND type = 'sleep');

-- ---------------------------------------------------------------------
-- 4. Presion arterial, temperatura y glucosa (los dos pacientes)
-- ---------------------------------------------------------------------
-- La serie larga llega del tensiometro y el glucometro conectados (origen
-- health_connect); las ultimas tres de cada una las anoto la cuidadora a mano, que
-- es como entran en la vida real cuando el aparato no esta sincronizado.

-- Presion: sistolica en value, diastolica en value_secondary. Dos al dia.
INSERT INTO vital_readings (patient_id, type, value, value_secondary, measured_at, source, meta)
SELECT p.pid, 'blood_pressure',
       ROUND((p.base + 10 * sin(EXTRACT(epoch FROM ts) / 86400.0) + (random() * 10 - 5))::numeric, 0),
       ROUND((p.base * 0.62 + (random() * 8 - 4))::numeric, 0),
       ts, 'wearable', '{"origin":"health_connect"}'::jsonb
FROM (VALUES ('33333333-3333-4333-8333-333333333333'::uuid, 132::numeric),
             ('33333333-3333-4333-8333-333333333334'::uuid, 138::numeric)) AS p(pid, base)
CROSS JOIN generate_series(date_trunc('day', now()) - interval '30 days' + interval '8 hours',
                           now() - interval '1 day', interval '12 hours') ts
WHERE NOT EXISTS (SELECT 1 FROM vital_readings vr
                   WHERE vr.patient_id = p.pid AND vr.type = 'blood_pressure');

-- Temperatura: una al dia.
INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT p.pid, 'temperature',
       ROUND((36.6 + (random() * 0.8 - 0.4))::numeric, 1),
       ts, 'wearable', '{"origin":"health_connect"}'::jsonb
FROM (VALUES ('33333333-3333-4333-8333-333333333333'::uuid),
             ('33333333-3333-4333-8333-333333333334'::uuid)) AS p(pid)
CROSS JOIN generate_series(date_trunc('day', now()) - interval '30 days' + interval '9 hours',
                           now() - interval '1 day', interval '1 day') ts
WHERE NOT EXISTS (SELECT 1 FROM vital_readings vr
                   WHERE vr.patient_id = p.pid AND vr.type = 'temperature');

-- Glucosa: Elena es diabetica (una en ayunas al dia, mas alta); Luis no.
INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT p.pid, 'glucose',
       ROUND((p.base + (random() * 40 - 20))::numeric, 0),
       ts, 'wearable', '{"origin":"health_connect"}'::jsonb
FROM (VALUES ('33333333-3333-4333-8333-333333333333'::uuid, 138::numeric),
             ('33333333-3333-4333-8333-333333333334'::uuid,  98::numeric)) AS p(pid, base)
CROSS JOIN generate_series(date_trunc('day', now()) - interval '30 days' + interval '7 hours 30 minutes',
                           now() - interval '1 day', interval '1 day') ts
WHERE NOT EXISTS (SELECT 1 FROM vital_readings vr
                   WHERE vr.patient_id = p.pid AND vr.type = 'glucose');

-- Mediciones a mano de la cuidadora, recientes y con nota. Algunas fuera de rango a
-- proposito: son las que el historial y el semaforo tienen que mostrar.
INSERT INTO vital_readings (patient_id, type, value, value_secondary, measured_at, source, meta)
SELECT v.pid, v.t, v.val, v.val2, v.ts, 'manual',
       jsonb_build_object('note', v.nota, 'recorded_by', '22222222-2222-4222-8222-222222222222')
FROM (VALUES
    ('33333333-3333-4333-8333-333333333333'::uuid, 'blood_pressure', 148::numeric, 92::numeric,
     now() - interval '1 day 2 hours', 'Se quejó de dolor de cabeza'),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'blood_pressure', 136, 84,
     now() - interval '3 hours', 'Después del desayuno'),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'glucose', 212, NULL,
     now() - interval '2 days 1 hour', 'Comió postre en el almuerzo'),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'glucose', 128, NULL,
     now() - interval '4 hours', 'En ayunas'),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'temperature', 36.8, NULL,
     now() - interval '4 hours', NULL),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'blood_pressure', 156, 94,
     now() - interval '5 hours', 'Tobillos hinchados'),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'temperature', 37.9, NULL,
     now() - interval '1 day 6 hours', 'Escalofríos en la tarde'),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'temperature', 37.1, NULL,
     now() - interval '5 hours', NULL),
    ('33333333-3333-4333-8333-333333333334'::uuid, 'glucose', 104, NULL,
     now() - interval '5 hours', 'En ayunas')
) AS v(pid, t, val, val2, ts, nota)
WHERE NOT EXISTS (SELECT 1 FROM vital_readings vr
                   WHERE vr.patient_id = v.pid AND vr.source = 'manual');

-- ---------------------------------------------------------------------
-- 5. Tratamientos de Luis (indicados por la doctora Soto)
-- ---------------------------------------------------------------------
INSERT INTO treatments (id, patient_id, status, specialty, prescribed_by, prescriber_role,
                        effective_from, note)
SELECT t.id, '33333333-3333-4333-8333-333333333334', 'vigente', t.sp, u.id, 'doctor',
       now() - t.desde, t.nota
FROM (VALUES
    ('cccccccc-0000-4000-8000-000000000001'::uuid, 'broncopulmonar', interval '45 days',
     'Control de EPOC. Ipratropio solo en crisis.'),
    ('cccccccc-0000-4000-8000-000000000002'::uuid, 'cardiologia', interval '20 days',
     'Insuficiencia cardíaca: controlar peso y edemas.')
) AS t(id, sp, desde, nota)
CROSS JOIN users u
WHERE lower(u.email) = 'doctora@agecare.cl'
ON CONFLICT DO NOTHING;

INSERT INTO treatment_items (id, treatment_id, name, dose_amount, dose_unit, instructions,
                             grace_window_min, action, is_prn, drug_code, prn_min_interval_min)
VALUES
  ('cccccccc-1000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001',
   'Salmeterol aerosol', 1, 'puff', 'Enjuagarse la boca después de usarlo.', 60, 'added', false,
   'salmeterol', NULL),
  ('cccccccc-1000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001',
   'Bromuro de ipratropio', 2, 'puff', 'Si tiene falta de aire.', 60, 'added', true,
   'ipratropio', 240),
  ('cccccccc-1000-4000-8000-000000000003', 'cccccccc-0000-4000-8000-000000000002',
   'Enalapril 10 mg', 10, 'mg', NULL, 60, 'added', false, 'enalapril', NULL),
  ('cccccccc-1000-4000-8000-000000000004', 'cccccccc-0000-4000-8000-000000000002',
   'Furosemida 40 mg', 40, 'mg', 'En la mañana, para no levantarse de noche.', 60, 'added', false,
   'furosemida', NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO treatment_item_times (treatment_item_id, time_of_day) VALUES
  ('cccccccc-1000-4000-8000-000000000001', '08:00'),
  ('cccccccc-1000-4000-8000-000000000001', '20:00'),
  ('cccccccc-1000-4000-8000-000000000003', '08:00'),
  ('cccccccc-1000-4000-8000-000000000003', '20:00'),
  ('cccccccc-1000-4000-8000-000000000004', '08:00')
ON CONFLICT DO NOTHING;

INSERT INTO treatment_item_days (treatment_item_id, day_of_week)
SELECT i, d
FROM unnest(ARRAY['cccccccc-1000-4000-8000-000000000001',
                  'cccccccc-1000-4000-8000-000000000003',
                  'cccccccc-1000-4000-8000-000000000004']::uuid[]) AS i
CROSS JOIN generate_series(1, 7) AS d
ON CONFLICT DO NOTHING;

-- Dosis de la ultima semana y de los proximos dos dias, como las dejaria el
-- generador. La cuidadora registra casi todas; alguna se omite o se salta.
WITH slots AS (
    SELECT ti.id AS item_id,
           ((d::date + tt.time_of_day) AT TIME ZONE 'America/Santiago') AS scheduled_at,
           random() AS r
    FROM treatment_items ti
    JOIN treatment_item_times tt ON tt.treatment_item_id = ti.id
    CROSS JOIN generate_series(CURRENT_DATE - 7, CURRENT_DATE + 2, interval '1 day') d
    WHERE ti.id IN ('cccccccc-1000-4000-8000-000000000001',
                    'cccccccc-1000-4000-8000-000000000003',
                    'cccccccc-1000-4000-8000-000000000004')
)
INSERT INTO scheduled_doses
    (treatment_item_id, scheduled_at, status, administered_at, logged_by, logged_at, reason)
SELECT item_id, scheduled_at,
       CASE WHEN scheduled_at > now() THEN 'pending'
            WHEN r < 0.85             THEN 'taken'
            WHEN r < 0.93             THEN 'skipped'
            ELSE                           'missed' END,
       CASE WHEN scheduled_at <= now() AND r < 0.85
            THEN scheduled_at + (random() * 20 || ' minutes')::interval END,
       CASE WHEN scheduled_at <= now() AND r < 0.93
            THEN '22222222-2222-4222-8222-222222222222'::uuid END,
       CASE WHEN scheduled_at <= now() AND r < 0.93
            THEN scheduled_at + (random() * 25 || ' minutes')::interval END,
       CASE WHEN scheduled_at <= now() AND r >= 0.85 AND r < 0.93
            THEN 'Estaba dormido y se le dio al despertar.' END
FROM slots
ON CONFLICT (treatment_item_id, scheduled_at) WHERE treatment_item_id IS NOT NULL DO NOTHING;

-- Un uso del inhalador SOS, para que el historial lo muestre.
INSERT INTO treatment_item_prn_uses (treatment_item_id, administered_at, reason, logged_by)
SELECT 'cccccccc-1000-4000-8000-000000000002', now() - interval '2 days',
       'Falta de aire al subir la escalera', '22222222-2222-4222-8222-222222222222'
WHERE NOT EXISTS (SELECT 1 FROM treatment_item_prn_uses
                   WHERE treatment_item_id = 'cccccccc-1000-4000-8000-000000000002');

-- ---------------------------------------------------------------------
-- 6. Bitacora y alerta activa de Luis
-- ---------------------------------------------------------------------
INSERT INTO care_observations (patient_id, author_id, category, note, observed_at)
SELECT '33333333-3333-4333-8333-333333333334', '22222222-2222-4222-8222-222222222222',
       o.cat, o.nota, now() - o.hace
FROM (VALUES ('mobility', 'Caminó hasta la plaza con bastón, se cansó al volver.', interval '3 days'),
             ('food',     'Almorzó la mitad, poco apetito.',                     interval '1 day 4 hours'),
             ('sleep',    'Durmió sentado por la falta de aire.',                interval '6 hours'))
     AS o(cat, nota, hace)
WHERE NOT EXISTS (SELECT 1 FROM care_observations
                   WHERE patient_id = '33333333-3333-4333-8333-333333333334');

INSERT INTO alerts (id, patient_id, type, severity, title, detail, dedup_key, status, created_at, updated_at)
VALUES ('aaaaaaa1-0000-4000-8000-000000000101',
        '33333333-3333-4333-8333-333333333334', 'vital_out_of_range', 'warning',
        'Saturación bajo el mínimo', 'SpO2 86% (mínimo configurado 88%).', 'spo2_low',
        'active', now() - interval '50 minutes', now() - interval '50 minutes')
ON CONFLICT (id) DO NOTHING;

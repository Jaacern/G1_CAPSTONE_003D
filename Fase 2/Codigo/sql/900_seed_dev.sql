-- =====================================================================
-- AgeCare — Datos de demostración (SOLO DESARROLLO)
-- =====================================================================
-- Contraseña de todos los usuarios de prueba: demo1234
--
-- Cambios respecto al esquema anterior (correcciones 2FN):
--   · users/patients: full_name reemplazado por first_name + last_name
--   · patients: conditions jsonb eliminado → patient_conditions
--   · medications: times/days_of_week jsonb eliminados → medication_times + medication_days
--   · scheduled_doses: patient_id eliminado
--   · alerts: update_at → updated_at
-- =====================================================================

-- ---------------------------------------------------------------
-- 1. Usuarios  (first_name + last_name, sin full_name)
-- ---------------------------------------------------------------
INSERT INTO users (id, email, password_hash, first_name, last_name, phone, locale) VALUES
  ('11111111-1111-4111-8111-111111111111',
   'ja.cernac@duocuc.cl',
   '$2b$12$PhFlUg1xEBTGKQuSYaBy.ODxdKlWAShWRiJxT0w85tC15kZaSNK/.',
   'Javier', 'Cerna', '+56912345678', 'es'),
  ('22222222-2222-4222-8222-222222222222',
   'rosa@cuidados.cl',
   '$2b$12$PhFlUg1xEBTGKQuSYaBy.ODxdKlWAShWRiJxT0w85tC15kZaSNK/.',
   'Rosa', 'Medina', '+56987654321', 'es');

-- ---------------------------------------------------------------
-- 2. Paciente  (first_name + last_name, sin conditions jsonb)
-- ---------------------------------------------------------------
INSERT INTO patients (id, first_name, last_name, rut_number, rut_dv, birth_date, sex) VALUES
  ('33333333-3333-4333-8333-333333333333',
   'Elena', 'Rosales', 5123456, 'K', '1944-03-12', 'F');

-- Condiciones médicas en tabla normalizada
INSERT INTO patient_conditions (patient_id, condition) VALUES
  ('33333333-3333-4333-8333-333333333333', 'hipertension'),
  ('33333333-3333-4333-8333-333333333333', 'diabetes_tipo_2');

-- Miembros del círculo de cuidado
INSERT INTO patient_members (patient_id, user_id, role, is_owner) VALUES
  ('33333333-3333-4333-8333-333333333333',
   '11111111-1111-4111-8111-111111111111', 'family', true),
  ('33333333-3333-4333-8333-333333333333',
   '22222222-2222-4222-8222-222222222222', 'caregiver', false);

INSERT INTO push_devices (id, user_id, push_token, platform, last_seen_at) VALUES
  ('55555555-5555-4555-8555-555555555555',
   '11111111-1111-4111-8111-111111111111',
   'demo-token-javier-android', 'android', now()),
  ('66666666-6666-4666-8666-666666666666',
   '22222222-2222-4222-8222-222222222222',
   'demo-token-rosa-ios', 'ios', now());

-- ---------------------------------------------------------------
-- 3. Wearable y umbrales
-- ---------------------------------------------------------------
INSERT INTO wearables (id, patient_id, provider, serial_number, model, battery_pct, last_sync_at) VALUES
  ('44444444-4444-4444-8444-444444444444',
   '33333333-3333-4333-8333-333333333333',
   'simulator', 'SIM-000001', 'AgeCare Band v1', 68, now() - interval '4 minutes');

INSERT INTO vital_thresholds (patient_id, type, min_value, max_value, updated_by) VALUES
  ('33333333-3333-4333-8333-333333333333', 'heart_rate', 50, 110,
   '22222222-2222-4222-8222-222222222222'),
  ('33333333-3333-4333-8333-333333333333', 'spo2', 92, NULL,
   '22222222-2222-4222-8222-222222222222');

-- ---------------------------------------------------------------
-- 4. Treinta días de signos vitales
-- ---------------------------------------------------------------
INSERT INTO vital_readings (patient_id, type, value, measured_at, source)
SELECT '33333333-3333-4333-8333-333333333333', 'heart_rate',
       ROUND((68 + 10 * sin(EXTRACT(epoch FROM ts) / 10800.0)
                 + (random() * 8 - 4))::numeric, 2),
       ts, 'wearable'
FROM generate_series(now() - interval '30 days', now(), interval '1 hour') ts;

INSERT INTO vital_readings (patient_id, type, value, measured_at, source)
SELECT '33333333-3333-4333-8333-333333333333', 'spo2',
       ROUND((97 + (random() * 2 - 1))::numeric, 2),
       ts, 'wearable'
FROM generate_series(now() - interval '30 days', now(), interval '2 hours') ts;

INSERT INTO vital_readings (patient_id, type, value, measured_at, source)
SELECT '33333333-3333-4333-8333-333333333333', 'steps',
       ROUND((1200 + random() * 4200)::numeric, 2),
       date_trunc('day', ts) + interval '22 hours', 'wearable'
FROM generate_series(now() - interval '30 days', now() - interval '1 day', interval '1 day') ts;

INSERT INTO vital_readings (patient_id, type, value, measured_at, source)
SELECT '33333333-3333-4333-8333-333333333333', 'sleep',
       ROUND((5.5 + random() * 3)::numeric, 2),
       date_trunc('day', ts) + interval '7 hours', 'wearable'
FROM generate_series(now() - interval '30 days', now() - interval '1 day', interval '1 day') ts;

-- Anomalías puntuales para disparar alertas demo
INSERT INTO vital_readings (patient_id, type, value, measured_at, source) VALUES
  ('33333333-3333-4333-8333-333333333333', 'spo2', 89.00,
   now() - interval '22 days' + interval '7 minutes', 'wearable'),
  ('33333333-3333-4333-8333-333333333333', 'spo2', 90.50,
   now() - interval '11 days' + interval '7 minutes', 'wearable'),
  ('33333333-3333-4333-8333-333333333333', 'heart_rate', 128.00,
   now() - interval '16 days' + interval '7 minutes', 'wearable'),
  ('33333333-3333-4333-8333-333333333333', 'heart_rate', 135.00,
   now() - interval '3 days' + interval '7 minutes', 'wearable');

-- ---------------------------------------------------------------
-- 5. Medicamentos (sin times/days_of_week JSON)
-- ---------------------------------------------------------------
INSERT INTO medications (id, patient_id, name, dose, instructions, start_date, grace_window_min) VALUES
  ('77777777-7777-4777-8777-777777777777',
   '33333333-3333-4333-8333-333333333333',
   'Losartán', '50 mg', 'Con un vaso de agua, antes de comer.',
   CURRENT_DATE - 60, 60),
  ('88888888-8888-4888-8888-888888888888',
   '33333333-3333-4333-8333-333333333333',
   'Metformina', '850 mg', 'Durante las comidas para evitar malestar.',
   CURRENT_DATE - 60, 45);

-- Horarios de toma (medication_times — normalizado 1FN)
INSERT INTO medication_times (medication_id, time_of_day) VALUES
  ('77777777-7777-4777-8777-777777777777', '08:00'),
  ('77777777-7777-4777-8777-777777777777', '20:00'),
  ('88888888-8888-4888-8888-888888888888', '08:00'),
  ('88888888-8888-4888-8888-888888888888', '14:00'),
  ('88888888-8888-4888-8888-888888888888', '20:00');

-- Días habilitados: todos los días (1-7) para ambos medicamentos
INSERT INTO medication_days (medication_id, day_of_week)
SELECT med_id, d
FROM (VALUES
  ('77777777-7777-4777-8777-777777777777'::uuid),
  ('88888888-8888-4888-8888-888888888888'::uuid)
) AS meds(med_id)
CROSS JOIN generate_series(1, 7) AS d;

-- ---------------------------------------------------------------
-- 6. Dosis programadas (sin patient_id — normalizado 2FN)
-- ---------------------------------------------------------------
WITH slots AS (
    SELECT m.id AS medication_id,
           ((d::date + mt.time_of_day) AT TIME ZONE 'America/Santiago') AS scheduled_at,
           random() AS r
    FROM medications m
    JOIN medication_times mt ON mt.medication_id = m.id
    JOIN medication_days  md ON md.medication_id = m.id
    CROSS JOIN generate_series(CURRENT_DATE - 30, CURRENT_DATE + 2, interval '1 day') d
    -- Solo los días habilitados para este medicamento
    WHERE EXTRACT(isodow FROM d::date) = md.day_of_week
)
INSERT INTO scheduled_doses
    (medication_id, scheduled_at, status, logged_by, logged_at, reason)
SELECT medication_id, scheduled_at,
       CASE WHEN scheduled_at > now()  THEN 'pending'
            WHEN r < 0.86              THEN 'taken'
            WHEN r < 0.93              THEN 'skipped'
            ELSE                            'missed' END,
       CASE WHEN scheduled_at <= now() AND r < 0.93
            THEN '22222222-2222-4222-8222-222222222222'::uuid END,
       CASE WHEN scheduled_at <= now() AND r < 0.93
            THEN scheduled_at + (random() * 25 || ' minutes')::interval END,
       CASE WHEN scheduled_at <= now() AND r >= 0.86 AND r < 0.93
            THEN 'La paciente indicó malestar estomacal.' END
FROM slots
ON CONFLICT (medication_id, scheduled_at) DO NOTHING;

-- ---------------------------------------------------------------
-- 7. Alertas (updated_at — typo corregido)
-- ---------------------------------------------------------------
INSERT INTO alerts (id, patient_id, type, severity, title, detail, dedup_key,
                    status, acknowledged_by, acknowledged_at,
                    resolved_by, resolved_at, resolution_note, created_at, updated_at) VALUES

  ('aaaaaaa1-0000-4000-8000-000000000001',
   '33333333-3333-4333-8333-333333333333', 'vital_out_of_range', 'warning',
   'Saturación bajo el mínimo', 'SpO2 89% (mínimo configurado 92%).', 'spo2_low',
   'resolved', '22222222-2222-4222-8222-222222222222',
   now() - interval '22 days' + interval '4 minutes',
   '22222222-2222-4222-8222-222222222222',
   now() - interval '22 days' + interval '35 minutes',
   'Se acomodó a la paciente y la saturación se normalizó.',
   now() - interval '22 days', now() - interval '22 days' + interval '35 minutes'),

  ('aaaaaaa1-0000-4000-8000-000000000002',
   '33333333-3333-4333-8333-333333333333', 'fall', 'critical',
   'Posible caída detectada', 'El wearable registró un impacto brusco.', 'fall',
   'resolved', '22222222-2222-4222-8222-222222222222',
   now() - interval '18 days' + interval '38 seconds',
   '22222222-2222-4222-8222-222222222222',
   now() - interval '18 days' + interval '12 minutes',
   'Falsa alarma: se le cayó el reloj al suelo.',
   now() - interval '18 days', now() - interval '18 days' + interval '12 minutes'),

  ('aaaaaaa1-0000-4000-8000-000000000003',
   '33333333-3333-4333-8333-333333333333', 'vital_out_of_range', 'warning',
   'Frecuencia cardíaca elevada', 'FC 128 lpm (máximo configurado 110).', 'hr_high',
   'resolved', '11111111-1111-4111-8111-111111111111',
   now() - interval '16 days' + interval '6 minutes',
   '11111111-1111-4111-8111-111111111111',
   now() - interval '16 days' + interval '50 minutes',
   'Había subido escaleras. Se estabilizó sola.',
   now() - interval '16 days', now() - interval '16 days' + interval '50 minutes'),

  ('aaaaaaa1-0000-4000-8000-000000000004',
   '33333333-3333-4333-8333-333333333333', 'missed_dose', 'warning',
   'Dosis no administrada', 'Metformina 850 mg de las 14:00 sin registro.', 'missed_dose',
   'resolved', '22222222-2222-4222-8222-222222222222',
   now() - interval '13 days' + interval '9 minutes',
   '22222222-2222-4222-8222-222222222222',
   now() - interval '13 days' + interval '15 minutes',
   'Se administró con retraso.',
   now() - interval '13 days', now() - interval '13 days' + interval '15 minutes'),

  ('aaaaaaa1-0000-4000-8000-000000000005',
   '33333333-3333-4333-8333-333333333333', 'vital_out_of_range', 'warning',
   'Saturación bajo el mínimo', 'SpO2 90.5% (mínimo configurado 92%).', 'spo2_low',
   'resolved', '22222222-2222-4222-8222-222222222222',
   now() - interval '11 days' + interval '3 minutes',
   '22222222-2222-4222-8222-222222222222',
   now() - interval '11 days' + interval '28 minutes',
   'Se revisó y la lectura se normalizó.',
   now() - interval '11 days', now() - interval '11 days' + interval '28 minutes'),

  ('aaaaaaa1-0000-4000-8000-000000000006',
   '33333333-3333-4333-8333-333333333333', 'sos', 'critical',
   'Botón de emergencia activado', 'La paciente activó el SOS desde la app.', 'sos',
   'resolved', '22222222-2222-4222-8222-222222222222',
   now() - interval '7 days' + interval '22 seconds',
   '22222222-2222-4222-8222-222222222222',
   now() - interval '7 days' + interval '9 minutes',
   'Caída en el baño sin lesiones. Se avisó al hijo.',
   now() - interval '7 days', now() - interval '7 days' + interval '9 minutes'),

  ('aaaaaaa1-0000-4000-8000-000000000007',
   '33333333-3333-4333-8333-333333333333', 'vital_out_of_range', 'critical',
   'Frecuencia cardíaca muy elevada', 'FC 135 lpm (máximo configurado 110).', 'hr_high',
   'acknowledged', '22222222-2222-4222-8222-222222222222',
   now() - interval '3 days' + interval '41 seconds',
   NULL, NULL, NULL,
   now() - interval '3 days', now() - interval '3 days' + interval '41 seconds'),

  ('aaaaaaa1-0000-4000-8000-000000000008',
   '33333333-3333-4333-8333-333333333333', 'wearable_offline', 'info',
   'Wearable sin sincronizar', 'Sin datos nuevos hace más de 2 horas.', 'wearable_offline',
   'active', NULL, NULL, NULL, NULL, NULL,
   now() - interval '35 minutes', now() - interval '35 minutes');

-- SOS con ubicación
INSERT INTO sos_events (patient_id, triggered_by, alert_id, note, latitude, longitude, created_at) VALUES
  ('33333333-3333-4333-8333-333333333333',
   '22222222-2222-4222-8222-222222222222',
   'aaaaaaa1-0000-4000-8000-000000000006',
   'Caída en el baño', -36.826700, -73.049800,
   now() - interval '7 days');

-- ---------------------------------------------------------------
-- 8. Entregas de notificaciones
-- ---------------------------------------------------------------
INSERT INTO alert_deliveries (alert_id, user_id, push_device_id, channel, status,
                              sent_at, delivered_at, opened_at, created_at)
SELECT a.id, pm.user_id,
       pd.id, 'push', 'opened',
       a.created_at + interval '2 seconds',
       a.created_at + ((6 + random() * 14) || ' seconds')::interval,
       COALESCE(a.acknowledged_at, a.created_at + interval '5 minutes'),
       a.created_at
FROM alerts a
JOIN patient_members pm ON pm.patient_id = a.patient_id AND pm.removed_at IS NULL
JOIN push_devices pd    ON pd.user_id = pm.user_id AND pd.is_active
WHERE a.status <> 'active';

INSERT INTO alert_deliveries (alert_id, user_id, push_device_id, channel, status,
                              sent_at, delivered_at, created_at)
SELECT a.id, pm.user_id, pd.id, 'push', 'delivered',
       a.created_at + interval '2 seconds',
       a.created_at + interval '11 seconds',
       a.created_at
FROM alerts a
JOIN patient_members pm ON pm.patient_id = a.patient_id AND pm.removed_at IS NULL
JOIN push_devices pd    ON pd.user_id = pm.user_id AND pd.is_active
WHERE a.status = 'active';

-- ---------------------------------------------------------------
-- 9. Preferencias y contactos de emergencia
-- ---------------------------------------------------------------
INSERT INTO notification_settings (user_id, alert_type, push_enabled) VALUES
  ('11111111-1111-4111-8111-111111111111', 'fall',               true),
  ('11111111-1111-4111-8111-111111111111', 'sos',                true),
  ('11111111-1111-4111-8111-111111111111', 'vital_out_of_range', true),
  ('11111111-1111-4111-8111-111111111111', 'missed_dose',        true),
  ('11111111-1111-4111-8111-111111111111', 'wearable_offline',   false),
  ('22222222-2222-4222-8222-222222222222', 'fall',               true),
  ('22222222-2222-4222-8222-222222222222', 'sos',                true),
  ('22222222-2222-4222-8222-222222222222', 'vital_out_of_range', true),
  ('22222222-2222-4222-8222-222222222222', 'missed_dose',        true),
  ('22222222-2222-4222-8222-222222222222', 'wearable_offline',   true);

INSERT INTO emergency_contacts (patient_id, full_name, relationship, phone, escalation_order) VALUES
  ('33333333-3333-4333-8333-333333333333', 'Javier Cerna',  'Hijo',      '+56912345678', 1),
  ('33333333-3333-4333-8333-333333333333', 'Rosa Medina',   'Cuidadora', '+56987654321', 2),
  ('33333333-3333-4333-8333-333333333333', 'SAMU',          'Emergencia','+56961313131', 3);

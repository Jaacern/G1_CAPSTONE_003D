-- AgeCare — Datos de demostración de los bloques 5 a 10
-- 998_seed_bloques_5_a_10.sql
--
-- 900_seed_dev.sql cubre el núcleo de salud (bloques 1 a 4) y deja 40 tablas
-- vacías. Este archivo las llena, y va aparte a propósito: no toca el seed del
-- equipo, así que los dos pueden evolucionar sin pisarse.
--
-- Se apoya en lo que 900 ya creó:
--   familiar   11111111-1111-4111-8111-111111111111  ja.cernac@duocuc.cl
--   cuidadora  22222222-2222-4222-8222-222222222222  rosa@cuidados.cl
--   adulto m.  99999999-9999-4999-8999-999999999999  elena@agecare.cl
--   paciente   33333333-3333-4333-8333-333333333333  Elena Rosales
--
-- Todo usa identificadores fijos con prefijo b... y ON CONFLICT DO NOTHING,
-- así que correrlo dos veces no duplica nada.

BEGIN;

-- ─────────────────────────── Bloque 5: archivos y bitácora ───────────────────
INSERT INTO files (id, patient_id, uploaded_by, storage_key, original_name,
                   mime_type, size_bytes, status, upload_expires_at, stored_at) VALUES
 ('bbbbbbb1-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','pac/elena/hemograma_2026_09.pdf',
  'hemograma_septiembre.pdf','application/pdf',184320,'stored', now(), now() - interval '20 days'),
 ('bbbbbbb1-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','pac/elena/almuerzo.jpg',
  'almuerzo.jpg','image/jpeg',96000,'stored', now(), now() - interval '2 days'),
 ('bbbbbbb1-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333',
  '11111111-1111-4111-8111-111111111111','pac/elena/bautizo_nieta.jpg',
  'bautizo_nieta.jpg','image/jpeg',240000,'stored', now(), now() - interval '10 days'),
 ('bbbbbbb1-0000-4000-8000-000000000004','33333333-3333-4333-8333-333333333333',
  '99999999-9999-4999-8999-999999999999','pac/elena/nota_voz_checkin.m4a',
  'nota_voz.m4a','audio/mp4',48000,'stored', now(), now() - interval '1 day'),
 ('bbbbbbb1-0000-4000-8000-000000000005','33333333-3333-4333-8333-333333333333',
  '99999999-9999-4999-8999-999999999999','pac/elena/cancion_tarde.mp3',
  'cancion_tarde.mp3','audio/mpeg',320000,'stored', now(), now() - interval '3 days'),
 ('bbbbbbb1-0000-4000-8000-000000000006','33333333-3333-4333-8333-333333333333',
  '11111111-1111-4111-8111-111111111111','pac/elena/receta_octubre.pdf',
  'receta_octubre.pdf','application/pdf',102400,'stored', now(), now() - interval '5 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO medical_documents (id, patient_id, file_id, category, title, description,
                               document_date, issued_by, added_by) VALUES
 ('bbbbbbb2-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  'bbbbbbb1-0000-4000-8000-000000000001','lab_result','Hemograma completo',
  'Control trimestral. Hemoglobina levemente baja.','2026-09-18','Laboratorio Biolab',
  '22222222-2222-4222-8222-222222222222'),
 ('bbbbbbb2-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  'bbbbbbb1-0000-4000-8000-000000000006','prescription','Receta de octubre',
  'Ajuste de dosis de losartán.','2026-10-05','Dr. Hernán Soto',
  '11111111-1111-4111-8111-111111111111')
ON CONFLICT (id) DO NOTHING;

INSERT INTO care_observations (id, patient_id, author_id, category, note, photo_file_id, observed_at) VALUES
 ('bbbbbbb3-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','food','Almorzó completo y sin ayuda. Buen ánimo.',
  'bbbbbbb1-0000-4000-8000-000000000002', now() - interval '2 days'),
 ('bbbbbbb3-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','sleep','Despertó tres veces en la noche. Dice que le dolía la cadera.',
  NULL, now() - interval '1 day'),
 ('bbbbbbb3-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','mobility','Caminó hasta el patio con el andador, sin apoyo adicional.',
  NULL, now() - interval '6 hours'),
 ('bbbbbbb3-0000-4000-8000-000000000004','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','mood','Tarde tranquila, estuvo escuchando radio.',
  NULL, now() - interval '3 hours')
ON CONFLICT (id) DO NOTHING;

-- Incidente leve: no necesita alerta.
INSERT INTO incidents (id, patient_id, reported_by, type, severity, occurred_at,
                       description, action_taken) VALUES
 ('bbbbbbb4-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','refusal','low', now() - interval '4 days',
  'Se negó a tomar el desayuno.','Se le ofreció una colación a media mañana y aceptó.')
ON CONFLICT (id) DO NOTHING;

-- Incidente crítico: el CHECK obliga a que traiga alerta, así que se crea la alerta.
INSERT INTO alerts (id, patient_id, type, severity, title, detail, status,
                    acknowledged_by, acknowledged_at, created_at) VALUES
 ('bbbbbbb5-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  'fall','critical','Caída detectada en el baño',
  'Reportada por la cuidadora. Golpe en la cadera derecha.','acknowledged',
  '11111111-1111-4111-8111-111111111111', now() - interval '3 days' + interval '2 minutes',
  now() - interval '3 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO incidents (id, patient_id, reported_by, type, severity, occurred_at,
                       description, action_taken, alert_id) VALUES
 ('bbbbbbb4-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','fall','critical', now() - interval '3 days',
  'Resbaló al salir de la ducha. Golpe en la cadera derecha.',
  'Se avisó al familiar y se solicitó control médico.','bbbbbbb5-0000-4000-8000-000000000001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO shift_notes (id, patient_id, author_id, shift_date, shift, note,
                         handover_to, acknowledged_by, acknowledged_at) VALUES
 ('bbbbbbb6-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222', current_date - 1,'morning',
  'Durmió mal. Vigilar la presión en la tarde y que no se salte el almuerzo.',
  '11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111',
  now() - interval '20 hours'),
 ('bbbbbbb6-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222', current_date,'morning',
  'Buena mañana. Caminó hasta el patio. Queda pendiente el control de presión de las 18:00.',
  '11111111-1111-4111-8111-111111111111', NULL, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO daily_checkins (id, patient_id, checkin_date, mood, pain_level,
                            slept_well, ate_well, note, voice_file_id, source) VALUES
 ('bbbbbbb7-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  current_date - 2,'good',2,true,true,'Me siento bien hoy.',NULL,'elder'),
 ('bbbbbbb7-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  current_date - 1,'bad',6,false,true,'Me dolió la cadera toda la noche.',
  'bbbbbbb1-0000-4000-8000-000000000004','elder'),
 ('bbbbbbb7-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333',
  current_date,'regular',4,false,true,NULL,NULL,'elder')
ON CONFLICT (id) DO NOTHING;

-- ─────────────────── Bloque 6: auditoría, dispositivo y uso ──────────────────
INSERT INTO record_access_log (patient_id, user_id, role, section, accessed_at) VALUES
 ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111','family','vitals', now() - interval '2 hours'),
 ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111','family','alerts', now() - interval '2 hours'),
 ('33333333-3333-4333-8333-333333333333','22222222-2222-4222-8222-222222222222','caregiver','medications', now() - interval '5 hours'),
 ('33333333-3333-4333-8333-333333333333','22222222-2222-4222-8222-222222222222','caregiver','logbook', now() - interval '5 hours'),
 ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111','family','documents', now() - interval '1 day');

INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, patient_id, created_at) VALUES
 ('22222222-2222-4222-8222-222222222222','dose_log','scheduled_doses', gen_random_uuid(),
  '33333333-3333-4333-8333-333333333333', now() - interval '5 hours'),
 ('11111111-1111-4111-8111-111111111111','alert_ack','alerts','bbbbbbb5-0000-4000-8000-000000000001',
  '33333333-3333-4333-8333-333333333333', now() - interval '3 days'),
 ('11111111-1111-4111-8111-111111111111','update','patients','33333333-3333-4333-8333-333333333333',
  '33333333-3333-4333-8333-333333333333', now() - interval '10 days');

INSERT INTO device_link_codes (id, patient_id, code_hash, created_by, expires_at, used_at, created_at) VALUES
 ('bbbbbbb8-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  repeat('a',64),'11111111-1111-4111-8111-111111111111',
  now() - interval '30 days' + interval '10 minutes', now() - interval '30 days' + interval '3 minutes',
  now() - interval '30 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO elder_devices (id, patient_id, link_code_id, user_id, device_label, platform,
                           device_fingerprint, session_token_hash, app_version, last_seen_at) VALUES
 ('bbbbbbb9-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  'bbbbbbb8-0000-4000-8000-000000000001','99999999-9999-4999-8999-999999999999',
  'Tablet del living','android', repeat('f',64), repeat('b',64),'1.4.0', now() - interval '1 hour')
ON CONFLICT (id) DO NOTHING;

INSERT INTO activity_sessions (patient_id, elder_device_id, activity, started_at, ended_at,
                               interactions_count, completed) VALUES
 ('33333333-3333-4333-8333-333333333333','bbbbbbb9-0000-4000-8000-000000000001','gallery',
  now() - interval '26 hours', now() - interval '26 hours' + interval '14 minutes', 11, true),
 ('33333333-3333-4333-8333-333333333333','bbbbbbb9-0000-4000-8000-000000000001','listening',
  now() - interval '25 hours', now() - interval '25 hours' + interval '32 minutes', 4, true),
 ('33333333-3333-4333-8333-333333333333','bbbbbbb9-0000-4000-8000-000000000001','music',
  now() - interval '3 days', now() - interval '3 days' + interval '9 minutes', 27, true),
 ('33333333-3333-4333-8333-333333333333','bbbbbbb9-0000-4000-8000-000000000001','checkin',
  now() - interval '2 hours', now() - interval '2 hours' + interval '90 seconds', 5, true),
 ('33333333-3333-4333-8333-333333333333','bbbbbbb9-0000-4000-8000-000000000001','gallery',
  now() - interval '20 minutes', NULL, 3, false);

-- ──────────────────────── Bloque 7: planes y cobros ──────────────────────────
INSERT INTO features (code, label, description, module, is_core) VALUES
 ('vitals_history','Historial de signos vitales','Serie histórica completa de mediciones.','health',true),
 ('alerts_realtime','Alertas en tiempo real','Aviso inmediato de caída, SOS y vital fuera de rango.','alerts',true),
 ('medication_plan','Plan de medicamentos','Registro de tomas y cálculo de adherencia.','medication',true),
 ('logbook','Bitácora del expediente','Observaciones, incidentes y notas de relevo.','logbook',false),
 ('documents','Documentos médicos','Subida y consulta de exámenes y recetas.','documents',false),
 ('assistant_ia','Asistente con IA','Consultas en lenguaje natural sobre el expediente.','assistant',false),
 ('elder_view','Vista del adulto mayor','Galería, contenido y Director Musical.','elder',false),
 ('marketplace_search','Búsqueda de cuidadoras','Buscar, contactar y reseñar cuidadoras.','marketplace',false),
 ('activity_reports','Reportes de actividad','Informes por rango de fechas.','reports',false)
ON CONFLICT (code) DO NOTHING;

-- Los planes se resuelven SIEMPRE por su code, nunca por un id fijo: 912 ya
-- pudo haber creado 'free' y 'premium' al migrar la columna de texto, con
-- identificadores propios. Buscar por code hace que este seed funcione igual
-- se haya corrido 912 antes o no.
INSERT INTO plans (code, name, description, tier, is_public, status, created_by, published_at) VALUES
 ('free','AgeCare Gratis',
  'Un paciente, alertas en tiempo real y 30 días de historial.',0,true,'active',
  '11111111-1111-4111-8111-111111111111', now() - interval '6 months'),
 ('premium','AgeCare Premium',
  'Pacientes ilimitados, historial completo, asistente de IA y marketplace.',1,true,'active',
  '11111111-1111-4111-8111-111111111111', now() - interval '6 months')
ON CONFLICT (code) DO NOTHING;

-- Completa nombre y descripción si 912 los creó con datos mínimos.
UPDATE plans SET name = 'AgeCare Gratis',
       description = 'Un paciente, alertas en tiempo real y 30 días de historial.'
 WHERE code = 'free' AND description IS NULL;
UPDATE plans SET name = 'AgeCare Premium',
       description = 'Pacientes ilimitados, historial completo, asistente de IA y marketplace.'
 WHERE code = 'premium' AND description IS NULL;

INSERT INTO plan_features (plan_id, feature_code, is_included)
SELECT p.id, v.code, v.incl
  FROM (VALUES
   ('free','vitals_history',true),('free','alerts_realtime',true),
   ('free','medication_plan',true),('free','logbook',false),
   ('free','assistant_ia',false),('free','marketplace_search',false),
   ('premium','vitals_history',true),('premium','alerts_realtime',true),
   ('premium','medication_plan',true),('premium','logbook',true),
   ('premium','documents',true),('premium','assistant_ia',true),
   ('premium','elder_view',true),('premium','marketplace_search',true),
   ('premium','activity_reports',true)
  ) AS v(plan, code, incl)
  JOIN plans p ON p.code = v.plan
ON CONFLICT (plan_id, feature_code) DO NOTHING;

INSERT INTO plan_limits (plan_id, limit_key, limit_value)
SELECT p.id, v.k, v.val
  FROM (VALUES
   ('free','max_patients',1),('free','max_members',3),('free','history_days',30),
   ('free','max_storage_mb',100),('free','ai_queries_month',0),
   ('premium','max_patients',NULL),('premium','max_members',NULL),
   ('premium','history_days',NULL),('premium','max_storage_mb',5000),
   ('premium','ai_queries_month',200)
  ) AS v(plan, k, val)
  JOIN plans p ON p.code = v.plan
ON CONFLICT (plan_id, limit_key) DO NOTHING;

-- Historial de precios: el premium subió en octubre. Sin solape, lo exige el EXCLUDE.
INSERT INTO plan_prices (id, plan_id, currency, period, amount, valid_from, valid_to, created_by)
SELECT v.id, p.id, 'CLP', v.periodo, v.monto, v.desde, v.hasta,
       '11111111-1111-4111-8111-111111111111'
  FROM (VALUES
   ('bbbbbbb0-0000-4000-8000-000000000001'::uuid,'monthly',4990::numeric,'2026-01-01'::timestamptz,'2026-10-01'::timestamptz),
   ('bbbbbbb0-0000-4000-8000-000000000002'::uuid,'monthly',5990::numeric,'2026-10-01'::timestamptz,NULL::timestamptz),
   ('bbbbbbb0-0000-4000-8000-000000000003'::uuid,'yearly',59900::numeric,'2026-10-01'::timestamptz,NULL::timestamptz)
  ) AS v(id, periodo, monto, desde, hasta)
  JOIN plans p ON p.code = 'premium'
ON CONFLICT (id) DO NOTHING;

-- La suscripción que creó 900 queda apuntando al plan premium del catálogo.
UPDATE subscriptions s SET plan_id = p.id
  FROM plans p WHERE p.code = 'premium' AND s.plan_id IS NULL;

INSERT INTO billing_events (subscription_id, plan_price_id, type, status, amount, currency,
                            period_start, period_end, provider_ref, provider_event_id, occurred_at)
SELECT s.id,'bbbbbbb0-0000-4000-8000-000000000002','charge','succeeded',5990,'CLP',
       date_trunc('month', now()), date_trunc('month', now()) + interval '1 month',
       'tx_9f2c01','evt_seed_001', date_trunc('month', now()) + interval '2 hours'
  FROM subscriptions s LIMIT 1
ON CONFLICT (provider_event_id) DO NOTHING;

INSERT INTO billing_events (subscription_id, type, status, amount, currency,
                            provider_ref, provider_event_id, occurred_at)
SELECT s.id,'charge','succeeded',4990,'CLP','tx_8a1b77','evt_seed_002',
       date_trunc('month', now()) - interval '1 month' + interval '2 hours'
  FROM subscriptions s LIMIT 1
ON CONFLICT (provider_event_id) DO NOTHING;

INSERT INTO billing_events (subscription_id, type, status, failure_reason,
                            provider_ref, provider_event_id, occurred_at)
SELECT s.id,'payment_failed','failed','Tarjeta sin fondos','tx_8a1b76','evt_seed_003',
       date_trunc('month', now()) - interval '1 month' + interval '1 hour'
  FROM subscriptions s LIMIT 1
ON CONFLICT (provider_event_id) DO NOTHING;

INSERT INTO usage_counters (subscription_id, limit_key, period_start, used_value, last_used_at)
SELECT s.id,'ai_queries_month', date_trunc('month', current_date)::date, 37, now() - interval '2 hours'
  FROM subscriptions s LIMIT 1
ON CONFLICT (subscription_id, limit_key, period_start) DO NOTHING;

INSERT INTO usage_counters (subscription_id, limit_key, period_start, used_value, last_used_at)
SELECT s.id,'max_storage_mb', date_trunc('month', current_date)::date, 412, now() - interval '1 day'
  FROM subscriptions s LIMIT 1
ON CONFLICT (subscription_id, limit_key, period_start) DO NOTHING;

-- ─────────────────── Bloque 8: comunicación y acompañamiento ─────────────────
INSERT INTO conversations (id, patient_id, type, user_id, last_message_at) VALUES
 ('bbbbbbc1-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333','human',NULL, now() - interval '3 hours'),
 ('bbbbbbc1-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333','assistant',
  '11111111-1111-4111-8111-111111111111', now() - interval '2 hours'),
 ('bbbbbbc1-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333','assistant',
  '22222222-2222-4222-8222-222222222222', now() - interval '6 hours')
ON CONFLICT (id) DO NOTHING;

INSERT INTO messages (id, conversation_id, sender_id, kind, body, file_id, created_at) VALUES
 ('bbbbbbc2-0000-4000-8000-000000000001','bbbbbbc1-0000-4000-8000-000000000001',
  '22222222-2222-4222-8222-222222222222','text','Don Juan, su mamá durmió mal anoche. Le avisé al doctor.',NULL, now() - interval '8 hours'),
 ('bbbbbbc2-0000-4000-8000-000000000002','bbbbbbc1-0000-4000-8000-000000000001',
  '11111111-1111-4111-8111-111111111111','text','Gracias Rosa. ¿Alcanzó a almorzar?',NULL, now() - interval '7 hours'),
 ('bbbbbbc2-0000-4000-8000-000000000003','bbbbbbc1-0000-4000-8000-000000000001',
  '22222222-2222-4222-8222-222222222222','photo','', 'bbbbbbb1-0000-4000-8000-000000000002', now() - interval '6 hours'),
 ('bbbbbbc2-0000-4000-8000-000000000004','bbbbbbc1-0000-4000-8000-000000000001',
  '99999999-9999-4999-8999-999999999999','voice', NULL,'bbbbbbb1-0000-4000-8000-000000000004', now() - interval '3 hours')
ON CONFLICT (id) DO NOTHING;

INSERT INTO message_receipts (message_id, recipient_id, delivered_at, read_at) VALUES
 ('bbbbbbc2-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111', now() - interval '8 hours' + interval '4 seconds', now() - interval '7 hours'),
 ('bbbbbbc2-0000-4000-8000-000000000002','22222222-2222-4222-8222-222222222222', now() - interval '7 hours' + interval '3 seconds', now() - interval '6 hours'),
 ('bbbbbbc2-0000-4000-8000-000000000003','11111111-1111-4111-8111-111111111111', now() - interval '6 hours' + interval '5 seconds', NULL),
 ('bbbbbbc2-0000-4000-8000-000000000004','11111111-1111-4111-8111-111111111111', now() - interval '3 hours' + interval '2 seconds', NULL),
 ('bbbbbbc2-0000-4000-8000-000000000004','22222222-2222-4222-8222-222222222222', NULL, NULL)
ON CONFLICT (message_id, recipient_id) DO NOTHING;

INSERT INTO assistant_queries (id, conversation_id, conversation_type, user_id, frozen_role_name,
                               query_text, response_text, latency_ms, created_at) VALUES
 ('bbbbbbc3-0000-4000-8000-000000000001','bbbbbbc1-0000-4000-8000-000000000002','assistant',
  '11111111-1111-4111-8111-111111111111','family',
  '¿Cómo ha estado la presión de mi mamá esta semana?',
  'En los últimos 7 días registró 14 mediciones de presión. Dos quedaron sobre el rango normal, el martes y el jueves. El resto estuvo dentro de lo esperado.',
  842, now() - interval '2 hours'),
 ('bbbbbbc3-0000-4000-8000-000000000002','bbbbbbc1-0000-4000-8000-000000000003','assistant',
  '22222222-2222-4222-8222-222222222222','caregiver',
  '¿Qué medicamentos le tocan hoy en la tarde?',
  'Hoy en la tarde corresponde losartán a las 18:00. La toma de las 14:00 ya fue registrada como administrada.',
  610, now() - interval '6 hours'),
 -- RF-58: el asistente invocado DENTRO del chat humano.
 ('bbbbbbc3-0000-4000-8000-000000000003','bbbbbbc1-0000-4000-8000-000000000001','human',
  '11111111-1111-4111-8111-111111111111','family',
  '@asistente ¿cuántas dosis se omitieron esta semana?',
  'Esta semana se omitieron 3 dosis de un total de 42 programadas. La adherencia del período es 92,9%.',
  733, now() - interval '5 hours')
ON CONFLICT (id) DO NOTHING;

INSERT INTO assistant_citations (query_id, source_table_name, source_record_id)
SELECT 'bbbbbbc3-0000-4000-8000-000000000001','vital_readings', vr.id
  FROM vital_readings vr WHERE vr.type='bp' ORDER BY vr.measured_at DESC LIMIT 2;

INSERT INTO assistant_citations (query_id, source_table_name, source_record_id)
SELECT 'bbbbbbc3-0000-4000-8000-000000000002','scheduled_doses', sd.id
  FROM scheduled_doses sd ORDER BY sd.scheduled_at DESC LIMIT 2;

INSERT INTO assistant_citations (query_id, source_table_name, source_record_id)
SELECT 'bbbbbbc3-0000-4000-8000-000000000003','scheduled_doses', sd.id
  FROM scheduled_doses sd WHERE sd.status='missed' LIMIT 3;

INSERT INTO gallery_photos (id, patient_id, published_by_user_id, file_id, caption, display_order) VALUES
 ('bbbbbbc4-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '11111111-1111-4111-8111-111111111111','bbbbbbb1-0000-4000-8000-000000000003',
  'El bautizo de la Emilia. Todos preguntaron por usted.',1)
ON CONFLICT (id) DO NOTHING;

INSERT INTO photo_reactions (photo_id, user_id, reaction_type) VALUES
 ('bbbbbbc4-0000-4000-8000-000000000001','99999999-9999-4999-8999-999999999999','heart');

INSERT INTO content_items (id, title, category, media_type, external_url, duration_seconds) VALUES
 ('bbbbbbc5-0000-4000-8000-000000000001','Radio Nostalgia','radio','audio','https://cdn.agecare.cl/radio/nostalgia', NULL),
 ('bbbbbbc5-0000-4000-8000-000000000002','Boleros de los 60','music','audio','https://cdn.agecare.cl/music/boleros60',2700),
 ('bbbbbbc5-0000-4000-8000-000000000003','Cuentos de la tierra','audiobook','audio','https://cdn.agecare.cl/libros/cuentos', 1800),
 ('bbbbbbc5-0000-4000-8000-000000000004','Ejercicios suaves sentado','exercise','video','https://cdn.agecare.cl/ejercicio/suave', 600),
 ('bbbbbbc5-0000-4000-8000-000000000005','Memoria de colores','game','interactive','https://cdn.agecare.cl/juegos/colores', NULL)
ON CONFLICT (id) DO NOTHING;

-- Un ítem alojado por AgeCare, no enlazado: usa un archivo de ámbito catalog,
-- que es justo lo que antes era imposible porque files exigía paciente.
INSERT INTO files (id, patient_id, uploaded_by, storage_key, original_name, mime_type,
                   size_bytes, status, upload_expires_at, stored_at, scope) VALUES
 ('bbbbbbc5-0000-4000-8000-00000000000a', NULL,'11111111-1111-4111-8111-111111111111',
  'catalogo/audio/relajacion_guiada.mp3','relajacion_guiada.mp3','audio/mpeg',
  4200000,'stored', now(), now() - interval '2 months','catalog')
ON CONFLICT (id) DO NOTHING;

INSERT INTO content_items (id, title, category, media_type, file_id, file_scope, duration_seconds) VALUES
 ('bbbbbbc5-0000-4000-8000-000000000006','Relajación guiada para dormir','audiobook','audio',
  'bbbbbbc5-0000-4000-8000-00000000000a','catalog', 900)
ON CONFLICT (id) DO NOTHING;

INSERT INTO content_playbacks (content_item_id, patient_id, user_id, playback_seconds,
                               completed, started_at, finished_at) VALUES
 ('bbbbbbc5-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  '99999999-9999-4999-8999-999999999999',2700,true, now() - interval '25 hours', now() - interval '25 hours' + interval '45 minutes'),
 ('bbbbbbc5-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333',
  '99999999-9999-4999-8999-999999999999',420,false, now() - interval '2 days', now() - interval '2 days' + interval '7 minutes'),
 ('bbbbbbc5-0000-4000-8000-000000000004','33333333-3333-4333-8333-333333333333',
  '99999999-9999-4999-8999-999999999999',600,true, now() - interval '1 day', now() - interval '1 day' + interval '10 minutes');

INSERT INTO music_creations (id, patient_id, created_by_user_id, title, file_id, duration_seconds) VALUES
 ('bbbbbbc6-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '99999999-9999-4999-8999-999999999999','Mi canción de la tarde',
  'bbbbbbb1-0000-4000-8000-000000000005',96)
ON CONFLICT (id) DO NOTHING;

-- Las dos formas de compartir de RF-67: con alguien del círculo, y por enlace
-- con vencimiento para la nieta que no tiene cuenta en AgeCare.
INSERT INTO creation_shares (music_creation_id, shared_with_user_id, shared_by) VALUES
 ('bbbbbbc6-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111',
  '99999999-9999-4999-8999-999999999999');

INSERT INTO creation_shares (music_creation_id, token_hash, expires_at, shared_by,
                             play_count, last_played_at) VALUES
 ('bbbbbbc6-0000-4000-8000-000000000001', repeat('e',64), now() + interval '7 days',
  '11111111-1111-4111-8111-111111111111', 3, now() - interval '1 day')
ON CONFLICT (token_hash) DO NOTHING;

INSERT INTO care_tasks (id, patient_id, assigned_to_user_id, created_by_user_id, title,
                        description, due_date, due_time, status, completed_at) VALUES
 ('bbbbbbc7-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',
  'Control de presión de la tarde','Tomar presión a las 18:00 y registrarla.',
  current_date,'18:00','pending',NULL),
 ('bbbbbbc7-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',
  'Baño asistido','Con silla de ducha, por la caída del martes.',
  current_date,'10:00','completed', now() - interval '6 hours'),
 ('bbbbbbc7-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',
  'Caminata al patio','15 minutos con andador si el clima acompaña.',
  current_date,'16:00','in_progress',NULL),
 ('bbbbbbc7-0000-4000-8000-000000000004','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',
  'Control médico cadera','Traumatología, Hospital Regional.',
  current_date + 4,'09:30','pending',NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO activity_reports (id, patient_id, requested_by, period_from, period_to, status,
                              doses_total, doses_taken, adherence_pct, observations, incidents,
                              tasks_done, storage_key, mime_type, size_bytes, generated_at) VALUES
 ('bbbbbbc8-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  '11111111-1111-4111-8111-111111111111', current_date - 30, current_date - 1,'ready',
  126, 118, 93.65, 18, 2, 24,'rep/elena/2026-10.pdf','application/pdf',284000, now() - interval '12 hours'),
 ('bbbbbbc8-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222', current_date - 7, current_date,'pending',
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)
ON CONFLICT (id) DO NOTHING;

-- Faltaban invitaciones y sesiones para completar el bloque 1.
-- created_at va explícito: la invitación histórica venció hace semanas y el
-- CHECK de vigencia exige que el vencimiento sea posterior a la creación.
INSERT INTO invitations (id, patient_id, email, role, token_hash, invited_by, expires_at,
                         accepted_at, accepted_by, created_at, updated_at) VALUES
 ('bbbbbbc9-0000-4000-8000-000000000001','33333333-3333-4333-8333-333333333333',
  'rosa@cuidados.cl','caregiver', repeat('c',64),'11111111-1111-4111-8111-111111111111',
  now() - interval '40 days' + interval '7 days', now() - interval '40 days' + interval '1 day',
  '22222222-2222-4222-8222-222222222222',
  now() - interval '40 days', now() - interval '39 days'),
 ('bbbbbbc9-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333',
  'hermana@correo.cl','family', repeat('d',64),'11111111-1111-4111-8111-111111111111',
  now() + interval '5 days', NULL, NULL, now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at) VALUES
 ('11111111-1111-4111-8111-111111111111', gen_random_uuid(), repeat('1',64), now() + interval '30 days'),
 ('22222222-2222-4222-8222-222222222222', gen_random_uuid(), repeat('2',64), now() + interval '30 days')
ON CONFLICT (token_hash) DO NOTHING;

-- ──────────────────────────── Bloque 9: marketplace ──────────────────────────
INSERT INTO specialties (code, label, description) VALUES
 ('alzheimer','Alzheimer y demencias','Acompañamiento en deterioro cognitivo y manejo de desorientación.'),
 ('movilidad_reducida','Movilidad reducida','Traslados, prevención de caídas y uso de ayudas técnicas.'),
 ('postoperatorio','Postoperatorio','Cuidado y control tras una cirugía o una hospitalización.'),
 ('diabetes','Diabetes','Control de glicemia, alimentación y cuidado de pies.'),
 ('paliativos','Cuidados paliativos','Acompañamiento y manejo del dolor en etapa avanzada.')
ON CONFLICT (code) DO NOTHING;

INSERT INTO caregiver_profiles (id, user_id, headline, bio, years_experience, hourly_rate,
                                currency, availability, accepts_overnight, status, published_at) VALUES
 ('bbbbbbd1-0000-4000-8000-000000000001','22222222-2222-4222-8222-222222222222',
  'Cuidadora con 8 años en demencias',
  'Técnico en enfermería de nivel superior. Trabajo con adultos mayores con deterioro cognitivo desde 2018, principalmente en domicilio. Me acomoda el turno de día y tengo experiencia con sondas y curaciones simples.',
  8, 6500,'CLP','part_time', false,'published', now() - interval '4 months')
ON CONFLICT (id) DO NOTHING;

INSERT INTO caregiver_specialties (profile_id, specialty_code, years) VALUES
 ('bbbbbbd1-0000-4000-8000-000000000001','alzheimer',8),
 ('bbbbbbd1-0000-4000-8000-000000000001','movilidad_reducida',5),
 ('bbbbbbd1-0000-4000-8000-000000000001','diabetes',3)
ON CONFLICT (profile_id, specialty_code) DO NOTHING;

INSERT INTO caregiver_languages (profile_id, language_code, proficiency) VALUES
 ('bbbbbbd1-0000-4000-8000-000000000001','es','native'),
 ('bbbbbbd1-0000-4000-8000-000000000001','en','basic')
ON CONFLICT (profile_id, language_code) DO NOTHING;

-- Comunas del Gran Concepción, códigos oficiales del INE.
INSERT INTO caregiver_zones (profile_id, commune_code, travel_fee) VALUES
 ('bbbbbbd1-0000-4000-8000-000000000001','08101', NULL),
 ('bbbbbbd1-0000-4000-8000-000000000001','08108', 3000),
 ('bbbbbbd1-0000-4000-8000-000000000001','08110', 3000)
ON CONFLICT (profile_id, commune_code) DO NOTHING;

-- Los certificados son archivos de ámbito caregiver: no pertenecen a ningún
-- expediente, por eso van sin patient_id (ver 913_files_general.sql).
INSERT INTO files (id, patient_id, uploaded_by, storage_key, original_name, mime_type,
                   size_bytes, status, upload_expires_at, stored_at, scope) VALUES
 ('bbbbbbd5-0000-4000-8000-000000000001', NULL,'22222222-2222-4222-8222-222222222222',
  'cert/rosa/titulo.pdf','titulo_enfermeria.pdf','application/pdf',320000,'stored',
  now(), now() - interval '4 months','caregiver'),
 ('bbbbbbd5-0000-4000-8000-000000000002', NULL,'22222222-2222-4222-8222-222222222222',
  'cert/rosa/rcp.pdf','certificado_rcp.pdf','application/pdf',145000,'stored',
  now(), now() - interval '4 months','caregiver')
ON CONFLICT (id) DO NOTHING;

INSERT INTO caregiver_certifications (id, profile_id, name, issuer, issued_at, expires_at,
                                      file_id, file_scope, verified_at, verified_by) VALUES
 ('bbbbbbd2-0000-4000-8000-000000000001','bbbbbbd1-0000-4000-8000-000000000001',
  'Técnico de Nivel Superior en Enfermería','Duoc UC','2018-12-20',NULL,
  'bbbbbbd5-0000-4000-8000-000000000001','caregiver', now() - interval '3 months',
  '11111111-1111-4111-8111-111111111111'),
 ('bbbbbbd2-0000-4000-8000-000000000002','bbbbbbd1-0000-4000-8000-000000000001',
  'Primeros auxilios y RCP','Cruz Roja Chilena','2025-04-10','2027-04-10',
  'bbbbbbd5-0000-4000-8000-000000000002','caregiver', NULL, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO contact_requests (id, profile_id, requester_id, patient_id, message, status,
                              channel, responded_at, created_at) VALUES
 ('bbbbbbd3-0000-4000-8000-000000000001','bbbbbbd1-0000-4000-8000-000000000001',
  '11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333',
  'Hola Rosa, busco apoyo de día para mi mamá en San Pedro. ¿Tiene disponibilidad?',
  'accepted','phone', now() - interval '40 days' + interval '6 hours', now() - interval '40 days')
ON CONFLICT (id) DO NOTHING;

-- RF-78: el familiar sí estuvo en el círculo con la cuidadora, así que puede reseñar.
INSERT INTO caregiver_reviews (id, profile_id, reviewed_user_id, author_id, patient_id,
                               rating, comment) VALUES
 ('bbbbbbd4-0000-4000-8000-000000000001','bbbbbbd1-0000-4000-8000-000000000001',
  '22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333',5,
  'Rosa lleva seis meses con mi mamá. Puntual, registra todo en la app y avisa apenas pasa algo.')
ON CONFLICT (id) DO NOTHING;

INSERT INTO support_articles (category, name, description, reference_price, currency,
                              external_url, is_featured, display_order, created_by) VALUES
 ('mobility','Andador con ruedas delanteras','Apoyo para caminar en interiores. Freno de presión y asiento.',
  38990,'CLP','https://ejemplo.cl/andador', true, 1,'11111111-1111-4111-8111-111111111111'),
 ('bathroom','Barra de apoyo con ventosa','Se instala sin perforar. Soporta hasta 100 kg.',
  12990,'CLP','https://ejemplo.cl/barra', true, 2,'11111111-1111-4111-8111-111111111111'),
 ('bathroom','Silla de ducha regulable','Altura regulable y patas antideslizantes.',
  29990,'CLP','https://ejemplo.cl/silla-ducha', false, 3,'11111111-1111-4111-8111-111111111111'),
 ('bedroom','Colchón antiescaras','Previene úlceras por presión en personas postradas.',
  89990,'CLP','https://ejemplo.cl/colchon', false, 4,'11111111-1111-4111-8111-111111111111'),
 ('medication','Pastillero semanal con alarma','Siete compartimentos y aviso sonoro por toma.',
  15990,'CLP','https://ejemplo.cl/pastillero', true, 5,'11111111-1111-4111-8111-111111111111'),
 ('safety','Alfombra antideslizante de baño','Reduce el riesgo de caída al salir de la ducha.',
  8990,'CLP','https://ejemplo.cl/alfombra', false, 6,'11111111-1111-4111-8111-111111111111'),
 ('hearing','Amplificador de sonido personal','Para conversar sin subir el volumen del televisor.',
  24990,'CLP','https://ejemplo.cl/amplificador', false, 7,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

-- ──────────────────────────── Bloque 10: analítica ───────────────────────────
INSERT INTO analytics_events (event_name, event_source, actor_type, actor_user_id, patient_id,
                              entity_type, entity_id, properties, occurred_at)
SELECT 'dose.taken','app','user','22222222-2222-4222-8222-222222222222',
       '33333333-3333-4333-8333-333333333333','scheduled_doses', sd.id,
       jsonb_build_object('minutos_de_retraso', 8,'medicamento','losartan'),
       sd.scheduled_at
  FROM scheduled_doses sd WHERE sd.status='taken' ORDER BY sd.scheduled_at DESC LIMIT 25;

INSERT INTO analytics_events (event_name, event_source, actor_type, actor_device_id, patient_id,
                              properties, occurred_at) VALUES
 ('gallery.photo_reacted','device','elder','bbbbbbb9-0000-4000-8000-000000000001',
  '33333333-3333-4333-8333-333333333333','{"tipo":"heart"}', now() - interval '26 hours'),
 ('music.creation_saved','device','elder','bbbbbbb9-0000-4000-8000-000000000001',
  '33333333-3333-4333-8333-333333333333','{"duracion_segundos":96}', now() - interval '3 days'),
 ('checkin.submitted','device','elder','bbbbbbb9-0000-4000-8000-000000000001',
  '33333333-3333-4333-8333-333333333333','{"animo":"regular","dolor":4}', now() - interval '2 hours');

INSERT INTO analytics_events (event_name, event_source, actor_type, patient_id,
                              entity_type, entity_id, properties, occurred_at) VALUES
 ('alert.escalated','job','system','33333333-3333-4333-8333-333333333333',
  'alerts','bbbbbbb5-0000-4000-8000-000000000001','{"contacto_orden":2}', now() - interval '3 days'),
 ('wellbeing.computed','job','system','33333333-3333-4333-8333-333333333333',
  NULL,NULL,'{"estado":"attention","motivos":2}', now() - interval '1 day');

INSERT INTO analytics_events (event_name, event_source, actor_type, actor_user_id, properties, occurred_at) VALUES
 ('auth.login','api','user','11111111-1111-4111-8111-111111111111','{"plataforma":"android"}', now() - interval '2 hours'),
 ('auth.login','api','user','22222222-2222-4222-8222-222222222222','{"plataforma":"ios"}', now() - interval '5 hours'),
 ('marketplace.profile_viewed','app','user','11111111-1111-4111-8111-111111111111',
  '{"perfil":"rosa","origen":"busqueda"}', now() - interval '41 days'),
 ('subscription.upgraded','api','user','11111111-1111-4111-8111-111111111111',
  '{"desde":"free","hacia":"premium"}', now() - interval '6 months');

COMMIT;

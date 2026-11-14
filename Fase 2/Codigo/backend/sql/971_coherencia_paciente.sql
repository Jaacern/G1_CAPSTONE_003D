-- Coherencia de paciente entre una ficha/registro y el archivo o la alerta que
-- adjunta (hallazgo 4 de la auditoria).
--
-- EL PROBLEMA
--   medical_documents, care_observations, incidents, daily_checkins y
--   sos_events guardan patient_id y ademas apuntan a files o a alerts con una
--   FK SIMPLE (solo por id). Nada obliga a que el archivo o la alerta sean del
--   MISMO paciente. Se podria adjuntar a la ficha del paciente A una foto o una
--   alerta del paciente B. El control quedaba solo en la aplicacion.
--
-- EL ARREGLO
--   El propio proyecto ya resolvio esto en otras tablas (caregiver_certifications,
--   content_items, market_products, elder_feed_items) con una FK COMPUESTA contra
--   files(id, scope). Aca se hace lo mismo con (id, patient_id): se agrega esa
--   clave unica al padre y la FK del hijo pasa a llevar tambien el patient_id,
--   asi el motor exige que coincidan. Para un archivo, que patient_id coincida
--   implica ademas scope='patient' (ck_files_scope_patient ata ambos).
--
--   Las FK con la columna de archivo/alerta opcional (foto, nota de voz, alerta
--   no critica) usan MATCH SIMPLE: si esa columna es NULL, no se valida nada, que
--   es lo correcto (no hay adjunto que comprobar).
--
--   Los datos actuales estan limpios (la verificacion dio 0 documentos con
--   archivo ajeno). Si hubiera una incoherencia en otra tabla, la migracion se
--   detiene antes con un mensaje que nombra la tabla, en vez de fallar al crear
--   la FK. Es atomica: no deja nada a medias.

-- 1. Claves unicas en los padres, requeridas como destino de la FK compuesta.
--    id ya es PK, asi que no cambian la unicidad; solo habilitan la FK.
ALTER TABLE files  ADD CONSTRAINT uq_files_id_patient  UNIQUE (id, patient_id);
ALTER TABLE alerts ADD CONSTRAINT uq_alerts_id_patient UNIQUE (id, patient_id);

-- 2. Revisar que no haya ya una incoherencia, para avisar claro por tabla.
DO $$
DECLARE malas int;
BEGIN
    SELECT count(*) INTO malas FROM medical_documents d
      JOIN files f ON f.id = d.file_id
     WHERE f.patient_id IS DISTINCT FROM d.patient_id;
    IF malas > 0 THEN RAISE EXCEPTION 'medical_documents: % con archivo de otro paciente. Corregir antes de aplicar 971.', malas; END IF;

    SELECT count(*) INTO malas FROM care_observations o
      JOIN files f ON f.id = o.photo_file_id
     WHERE f.patient_id IS DISTINCT FROM o.patient_id;
    IF malas > 0 THEN RAISE EXCEPTION 'care_observations: % con foto de otro paciente. Corregir antes de aplicar 971.', malas; END IF;

    SELECT count(*) INTO malas FROM incidents i
      JOIN files f ON f.id = i.photo_file_id
     WHERE f.patient_id IS DISTINCT FROM i.patient_id;
    IF malas > 0 THEN RAISE EXCEPTION 'incidents: % con foto de otro paciente. Corregir antes de aplicar 971.', malas; END IF;

    SELECT count(*) INTO malas FROM daily_checkins c
      JOIN files f ON f.id = c.voice_file_id
     WHERE f.patient_id IS DISTINCT FROM c.patient_id;
    IF malas > 0 THEN RAISE EXCEPTION 'daily_checkins: % con nota de voz de otro paciente. Corregir antes de aplicar 971.', malas; END IF;

    SELECT count(*) INTO malas FROM sos_events s
      JOIN alerts a ON a.id = s.alert_id
     WHERE a.patient_id IS DISTINCT FROM s.patient_id;
    IF malas > 0 THEN RAISE EXCEPTION 'sos_events: % con alerta de otro paciente. Corregir antes de aplicar 971.', malas; END IF;

    SELECT count(*) INTO malas FROM incidents i
      JOIN alerts a ON a.id = i.alert_id
     WHERE a.patient_id IS DISTINCT FROM i.patient_id;
    IF malas > 0 THEN RAISE EXCEPTION 'incidents(alert): % con alerta de otro paciente. Corregir antes de aplicar 971.', malas; END IF;
END $$;

-- 3. Reemplazar cada FK simple por una compuesta (hijo + patient_id).
ALTER TABLE medical_documents DROP CONSTRAINT fk_medical_documents_file;
ALTER TABLE medical_documents
    ADD CONSTRAINT fk_medical_documents_file
        FOREIGN KEY (file_id, patient_id) REFERENCES files (id, patient_id) ON DELETE RESTRICT;

ALTER TABLE care_observations DROP CONSTRAINT fk_care_observations_photo;
ALTER TABLE care_observations
    ADD CONSTRAINT fk_care_observations_photo
        FOREIGN KEY (photo_file_id, patient_id) REFERENCES files (id, patient_id) ON DELETE RESTRICT;

ALTER TABLE incidents DROP CONSTRAINT fk_incidents_photo;
ALTER TABLE incidents
    ADD CONSTRAINT fk_incidents_photo
        FOREIGN KEY (photo_file_id, patient_id) REFERENCES files (id, patient_id) ON DELETE RESTRICT;

ALTER TABLE daily_checkins DROP CONSTRAINT fk_daily_checkins_voice;
ALTER TABLE daily_checkins
    ADD CONSTRAINT fk_daily_checkins_voice
        FOREIGN KEY (voice_file_id, patient_id) REFERENCES files (id, patient_id) ON DELETE RESTRICT;

ALTER TABLE sos_events DROP CONSTRAINT fk_sos_events_alert;
ALTER TABLE sos_events
    ADD CONSTRAINT fk_sos_events_alert
        FOREIGN KEY (alert_id, patient_id) REFERENCES alerts (id, patient_id) ON DELETE RESTRICT;

ALTER TABLE incidents DROP CONSTRAINT fk_incidents_alert;
ALTER TABLE incidents
    ADD CONSTRAINT fk_incidents_alert
        FOREIGN KEY (alert_id, patient_id) REFERENCES alerts (id, patient_id) ON DELETE RESTRICT;

-- Revierte 971_coherencia_paciente.sql: vuelve a las FK simples (solo por id)
-- y quita las claves unicas (id, patient_id) de los padres. No pierde datos.

ALTER TABLE medical_documents DROP CONSTRAINT fk_medical_documents_file;
ALTER TABLE medical_documents
    ADD CONSTRAINT fk_medical_documents_file
        FOREIGN KEY (file_id) REFERENCES files (id) ON DELETE RESTRICT;

ALTER TABLE care_observations DROP CONSTRAINT fk_care_observations_photo;
ALTER TABLE care_observations
    ADD CONSTRAINT fk_care_observations_photo
        FOREIGN KEY (photo_file_id) REFERENCES files (id) ON DELETE RESTRICT;

ALTER TABLE incidents DROP CONSTRAINT fk_incidents_photo;
ALTER TABLE incidents
    ADD CONSTRAINT fk_incidents_photo
        FOREIGN KEY (photo_file_id) REFERENCES files (id) ON DELETE RESTRICT;

ALTER TABLE daily_checkins DROP CONSTRAINT fk_daily_checkins_voice;
ALTER TABLE daily_checkins
    ADD CONSTRAINT fk_daily_checkins_voice
        FOREIGN KEY (voice_file_id) REFERENCES files (id) ON DELETE RESTRICT;

ALTER TABLE sos_events DROP CONSTRAINT fk_sos_events_alert;
ALTER TABLE sos_events
    ADD CONSTRAINT fk_sos_events_alert
        FOREIGN KEY (alert_id) REFERENCES alerts (id) ON DELETE RESTRICT;

ALTER TABLE incidents DROP CONSTRAINT fk_incidents_alert;
ALTER TABLE incidents
    ADD CONSTRAINT fk_incidents_alert
        FOREIGN KEY (alert_id) REFERENCES alerts (id) ON DELETE RESTRICT;

ALTER TABLE files  DROP CONSTRAINT uq_files_id_patient;
ALTER TABLE alerts DROP CONSTRAINT uq_alerts_id_patient;

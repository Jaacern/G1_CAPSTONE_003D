-- Revierte 972_prescriptor_real.sql.
--
-- RE-INTRODUCE la atribucion que 972 corrigio: los tratamientos de arranque de
-- un familiar vuelven a quedar como 'doctor' (es lo que significa deshacer el
-- arreglo). Se hace antes de restaurar el CHECK mas estrecho, para no chocar
-- con el. Un prescriptor 'caregiver' legitimo no se toca.

UPDATE treatments SET prescriber_role = 'doctor' WHERE prescriber_role = 'family';

ALTER TABLE treatments DROP CONSTRAINT IF EXISTS ck_treatments_role;
ALTER TABLE treatments
    ADD CONSTRAINT ck_treatments_role
        CHECK (prescriber_role IN ('doctor', 'caregiver'));

COMMENT ON COLUMN treatments.prescriber_role IS
    'Rol de quien prescribió. doctor o caregiver.';

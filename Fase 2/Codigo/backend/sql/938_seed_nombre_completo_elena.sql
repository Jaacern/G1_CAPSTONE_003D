-- AgeCare — Datos de demostracion (SOLO DESARROLLO)
-- 938_seed_nombre_completo_elena.sql — La paciente de prueba con sus cuatro nombres
-- MIGRACION IDEMPOTENTE
--
-- Desde 934 el paciente guarda primer nombre, segundo nombre, primer apellido
-- y segundo apellido. La paciente de demostracion seguia como "Elena Rosales",
-- que no es como se identifica a una persona en Chile ni como aparece en su
-- carnet. Queda como Elena Rosa Rosales Riquelme.
--
-- Solo completa lo que esta vacio: si alguien ya corrigio el nombre a mano en
-- su base, no se le pisa.

UPDATE patients
   SET second_name = 'Rosa'
 WHERE id = '33333333-3333-4333-8333-333333333333'
   AND second_name IS NULL;

UPDATE patients
   SET second_last_name = 'Riquelme'
 WHERE id = '33333333-3333-4333-8333-333333333333'
   AND second_last_name IS NULL;

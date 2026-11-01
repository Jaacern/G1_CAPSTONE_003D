-- AgeCare — Correccion
-- 924_proficiency_largo.sql — La columna no alcanzaba para su propio default
--
-- EL PROBLEMA
--   caregiver_languages.proficiency se declaro varchar(12) con DEFAULT
--   'conversational', que tiene 14 caracteres. El valor por defecto no cabia
--   en su propia columna.
--
--   El resultado es que insertar un idioma sin indicar el nivel fallaba
--   siempre con "value too long for type character varying(12)", y pasarlo
--   explicito tambien. De los cuatro niveles que acepta el CHECK, uno era
--   imposible de guardar.
--
--   No se noto antes porque los datos de demo usan 'basic' y 'native', que si
--   caben. Aparecio al escribir el guardado del perfil, que inserta idiomas
--   sin especificar el nivel y por lo tanto usa el default.
--
-- LA CORRECCION
--   Se amplia la columna a 14, que es el largo del valor mas largo que el
--   CHECK permite. Ampliar un varchar no reescribe la tabla ni toca las filas
--   que ya estan.

ALTER TABLE caregiver_languages
    ALTER COLUMN proficiency TYPE varchar(14);

COMMENT ON COLUMN caregiver_languages.proficiency IS
    'Nivel de dominio del idioma. El largo de la columna alcanza para el valor mas largo del CHECK, que es conversational.';

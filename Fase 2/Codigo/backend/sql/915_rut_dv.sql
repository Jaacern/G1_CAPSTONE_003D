-- AgeCare — Integridad del RUT
-- 915_rut_dv.sql — El dígito verificador deja de poder estar malo
--
-- EL PROBLEMA
--   patients.rut_dv se deriva de rut_number por el módulo 11, y el archivo
--   104_patients.sql ya lo decía: "se almacena por conveniencia de validación,
--   no como dato independiente". Pero nada lo verificaba. El único CHECK que
--   había comprobaba el FORMATO (un dígito o la letra K), no que el dígito
--   fuera el correcto.
--
--   No es teórico. El paciente de demostración venía con 5.123.456-K y el
--   dígito que corresponde a ese número es el 1. O sea, los datos con los que
--   se probaba el sistema tenían un RUT inválido y nadie lo notó, porque nada
--   podía notarlo.
--
-- LA CORRECCIÓN
--   Una función inmutable que calcula el dígito, y un CHECK que compara el
--   guardado contra el calculado. A partir de acá un RUT mal digitado no entra.
--
--   No se convierte en columna GENERATED porque eso obliga a recrear la
--   columna y a cambiar el seed del equipo, que la escribe explícitamente. Con
--   el CHECK se consigue lo mismo (es imposible guardar un valor inconsistente)
--   sin tocar archivos ajenos.

CREATE OR REPLACE FUNCTION rut_digito_verificador(numero integer)
RETURNS char(1)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    suma        integer := 0;
    multiplo    integer := 2;
    resto       integer;
    n           integer;
BEGIN
    IF numero IS NULL THEN
        RETURN NULL;
    END IF;

    n := numero;
    -- Se recorre de derecha a izquierda multiplicando por la serie 2,3,4,5,6,7
    -- y volviendo a empezar.
    WHILE n > 0 LOOP
        suma     := suma + (n % 10) * multiplo;
        multiplo := CASE WHEN multiplo = 7 THEN 2 ELSE multiplo + 1 END;
        n        := n / 10;
    END LOOP;

    resto := 11 - (suma % 11);
    RETURN CASE resto
             WHEN 11 THEN '0'
             WHEN 10 THEN 'K'
             ELSE resto::text
           END;
END;
$$;

COMMENT ON FUNCTION rut_digito_verificador(integer) IS
    'Calcula el dígito verificador de un RUT chileno por el módulo 11. IMMUTABLE: para el mismo número devuelve siempre lo mismo, que es lo que permite usarla dentro de un CHECK.';

-- Corrige los dígitos que ya estuvieran mal guardados, incluido el del seed.
UPDATE patients
   SET rut_dv = rut_digito_verificador(rut_number)
 WHERE rut_number IS NOT NULL
   AND (rut_dv IS DISTINCT FROM rut_digito_verificador(rut_number));

-- Desde aquí, el motor rechaza cualquier RUT cuyo dígito no corresponda.
ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_rut_dv_correcto;
ALTER TABLE patients ADD CONSTRAINT ck_patients_rut_dv_correcto
    CHECK (rut_number IS NULL OR rut_dv = rut_digito_verificador(rut_number));

COMMENT ON COLUMN patients.rut_dv IS
    'Dígito verificador del RUT. Es un dato DERIVADO de rut_number por el módulo 11, y un CHECK contra rut_digito_verificador() impide que quede inconsistente. Se almacena para poder mostrarlo y buscarlo sin recalcular.';

-- AgeCare — Datos de demostracion (SOLO DESARROLLO)
-- 999_unico_circulo_demo.sql — Un solo circulo de demostracion, completo
-- MIGRACION IDEMPOTENTE
--
-- POR QUE
--   Los seed fueron sumando cuentas y pacientes de prueba (un usuario
--   externo y un segundo circulo de relleno). Para mostrar el
--   producto basta un circulo: cinco cuentas, una por rol, y dos adultos
--   mayores con la ficha completa.
--
--     familiar@agecare.cl        Daniela Ignacia Fuentes Rosales    hija
--     cuidadora@agecare.cl       Marisol Andrea Tapia Vergara       cuidadora
--     doctora@agecare.cl         Carolina Beatriz Soto Valenzuela   medica
--     adultomayor@agecare.cl     Elena Rosa Rosales Riquelme        adulta mayor
--     administrador@agecare.cl   Tomas Ignacio Bravo Lagos          personal
--
--     Adultos mayores: Elena Rosa Rosales Riquelme y Luis Alberto Fuentes
--     Rojas, matrimonio que vive en la misma casa. Daniela es hija de ambos.
--
-- COMO BORRA (y por que no borra "todo lo demas")
--   Solo elimina las filas de seed que ESTA base conoce, por id. Una regla
--   generica ("todas las cuentas salvo cinco") se ejecutaria sola en cada
--   arranque y borraria cuentas reales en cualquier servidor donde esto
--   corriera. Por id, lo peor que pasa es no encontrar nada.
--   El borrado sigue las claves foraneas hacia abajo (todas son RESTRICT) y es
--   por fila: si algo lo impide, p. ej. el audit_log, que es inmutable por
--   diseño, esa cuenta se conserva y se avisa con un NOTICE.
--   En produccion estas cuentas se borran antes de salir.

-- ---------------------------------------------------------------------
-- 1. Borrado en cascada por claves foraneas (temporal, vive en esta sesion)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.borrar_cascada(p_tabla regclass, p_donde text, p_nivel int DEFAULT 0)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
    r           record;
    hijo_cols   text;
    hijo_nulos  text;
    padre_cols  text;
BEGIN
    IF p_nivel > 12 THEN
        RAISE EXCEPTION 'ciclo de claves foraneas alrededor de %', p_tabla;
    END IF;

    FOR r IN
        SELECT c.conrelid, c.conkey, c.confkey
          FROM pg_constraint c
         WHERE c.contype = 'f' AND c.confrelid = p_tabla AND c.conparentid = 0
    LOOP
        SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord),
               string_agg(quote_ident(a.attname) || ' = NULL', ', ' ORDER BY k.ord)
          INTO hijo_cols, hijo_nulos
          FROM unnest(r.conkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = r.conrelid AND a.attnum = k.attnum;

        SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord)
          INTO padre_cols
          FROM unnest(r.confkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = p_tabla AND a.attnum = k.attnum;

        IF r.conrelid = p_tabla THEN
            -- Autorreferencia (deactivated_by, supersedes_id): se suelta el enlace.
            EXECUTE format('UPDATE %s SET %s WHERE (%s) IN (SELECT %s FROM %s WHERE %s)',
                           p_tabla, hijo_nulos, hijo_cols, padre_cols, p_tabla, p_donde);
        ELSE
            PERFORM pg_temp.borrar_cascada(
                r.conrelid,
                format('(%s) IN (SELECT %s FROM %s WHERE %s)', hijo_cols, padre_cols, p_tabla, p_donde),
                p_nivel + 1);
        END IF;
    END LOOP;

    EXECUTE format('DELETE FROM %s WHERE %s', p_tabla, p_donde);
END;
$f$;

-- ---------------------------------------------------------------------
-- 2. Fuera lo que sobra: pacientes primero, luego cuentas
-- ---------------------------------------------------------------------
DO $$
DECLARE
    x uuid;
BEGIN
    -- Pacientes de relleno del antiguo 999_seed_demo_extra.
    FOR x IN
        SELECT id FROM patients
         WHERE id IN ('b1cabd30-7448-4581-8600-48307fbc6a98',
                      '1f9d33f9-7639-46c7-94bd-f6d93fdf8245',
                      'd983c076-5d00-4790-a070-8f7950b635de')
    LOOP
        BEGIN
            PERFORM pg_temp.borrar_cascada('patients', format('id = %L', x));
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'paciente % se conserva: %', x, SQLERRM;
        END;
    END LOOP;

    -- Cuentas de relleno: el usuario externo y las del segundo circulo.
    FOR x IN
        SELECT id FROM users
         WHERE id IN ('eeeeeee1-0000-4000-8000-000000000001',
                      '85c14965-81ec-4037-8564-bb080cbf9da8',
                      'b985337d-0c2f-40f7-8a64-ec1df8973aaf',
                      '4a3cfa1a-fdc5-4245-9935-9b902250d906')
    LOOP
        BEGIN
            PERFORM pg_temp.borrar_cascada('users', format('id = %L', x));
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'cuenta % se conserva: %', x, SQLERRM;
        END;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 3. Las cinco cuentas, con nombre en cuatro partes, RUT y telefono
--    (el dígito verificador lo calcula la misma funcion del CHECK)
-- ---------------------------------------------------------------------
UPDATE users u
   SET first_name       = d.nombre,
       second_name      = d.segundo,
       last_name        = d.apellido,
       second_last_name = d.materno,
       rut_number       = COALESCE(u.rut_number, d.rut),
       rut_dv           = rut_digito_verificador(COALESCE(u.rut_number, d.rut)),
       phone            = COALESCE(u.phone, d.telefono)
  FROM (VALUES
    ('familiar@agecare.cl',      'Daniela',  'Ignacia',  'Fuentes', 'Rosales',   14876543, '+56912345678'),
    ('cuidadora@agecare.cl',     'Marisol',  'Andrea',   'Tapia',   'Vergara',   15234567, '+56987654321'),
    ('doctora@agecare.cl',       'Carolina', 'Beatriz',  'Soto',    'Valenzuela',13456789, '+56922223333'),
    ('adultomayor@agecare.cl',   'Elena',    'Rosa',     'Rosales', 'Riquelme',   5123456, '+56911112222'),
    ('administrador@agecare.cl', 'Tomás',    'Ignacio',  'Bravo',   'Lagos',     16234567, '+56933334444')
  ) AS d(correo, nombre, segundo, apellido, materno, rut, telefono)
 WHERE lower(u.email) = d.correo
   AND NOT EXISTS (SELECT 1 FROM users o
                    WHERE o.rut_number = COALESCE(u.rut_number, d.rut) AND o.id <> u.id);

-- ---------------------------------------------------------------------
-- 4. Los dos adultos mayores: un matrimonio, misma casa, ficha completa
--    Solo se rellena lo que esta vacio, salvo el estado civil y el domicilio
--    de Luis, que cambian porque la historia familiar cambio.
-- ---------------------------------------------------------------------
UPDATE patients
   SET address        = COALESCE(address,        'Pasaje Los Lirios 456, Concepción'),
       marital_status = COALESCE(marital_status, 'casado'),
       insurance      = COALESCE(insurance,      'fonasa'),
       complexity     = COALESCE(complexity,     'alta'),
       priority       = COALESCE(priority,       'media'),
       rcv_level      = COALESCE(rcv_level,      'alto')
 WHERE id = '33333333-3333-4333-8333-333333333333';

UPDATE patients
   SET address        = 'Pasaje Los Lirios 456, Concepción',
       marital_status = 'casado',
       insurance      = COALESCE(insurance,      'fonasa'),
       complexity     = COALESCE(complexity,     'moderada'),
       priority       = COALESCE(priority,       'media'),
       rcv_level      = COALESCE(rcv_level,      'moderado')
 WHERE id = '33333333-3333-4333-8333-333333333334';

-- Circulo completo en los dos: la medica tambien atiende a Luis.
INSERT INTO patient_members (patient_id, user_id, role, is_owner)
SELECT '33333333-3333-4333-8333-333333333334', u.id, 'doctor', false
  FROM users u
 WHERE lower(u.email) = 'doctora@agecare.cl'
   AND EXISTS (SELECT 1 FROM patients p WHERE p.id = '33333333-3333-4333-8333-333333333334')
ON CONFLICT (patient_id, user_id) DO NOTHING;

-- Daniela es hija de los dos; la cuidadora figura como cuidadora.
UPDATE patient_members
   SET relationship = 'hija'
 WHERE user_id = '11111111-1111-4111-8111-111111111111'
   AND patient_id IN ('33333333-3333-4333-8333-333333333333',
                      '33333333-3333-4333-8333-333333333334');

UPDATE patient_members
   SET relationship = 'cuidador'
 WHERE user_id = '22222222-2222-4222-8222-222222222222'
   AND relationship IS NULL
   AND patient_id IN ('33333333-3333-4333-8333-333333333333',
                      '33333333-3333-4333-8333-333333333334');

-- Contactos de emergencia de texto libre (seed 900): se reconocen por su
-- orden de escalamiento y su telefono, que son los de las dos cuentas.
UPDATE emergency_contacts
   SET first_name = 'Daniela', last_name = 'Fuentes Rosales', relationship = 'Hija'
 WHERE patient_id = '33333333-3333-4333-8333-333333333333'
   AND member_user_id IS NULL AND escalation_order = 1 AND phone = '+56912345678';

UPDATE emergency_contacts
   SET first_name = 'Marisol', last_name = 'Tapia Vergara', relationship = 'Cuidadora'
 WHERE patient_id = '33333333-3333-4333-8333-333333333333'
   AND member_user_id IS NULL AND escalation_order = 2 AND phone = '+56987654321';

UPDATE emergency_contacts
   SET notes = 'Hija, administra el perfil'
 WHERE patient_id = '33333333-3333-4333-8333-333333333334'
   AND member_user_id = '11111111-1111-4111-8111-111111111111';

-- ---------------------------------------------------------------------
-- 5. Textos libres del seed que nombraban a las personas de antes
-- ---------------------------------------------------------------------
UPDATE messages
   SET body = 'Daniela, su mamá durmió mal anoche. Le avisé al doctor.'
 WHERE id = 'bbbbbbc2-0000-4000-8000-000000000001';

UPDATE messages
   SET body = 'Gracias Marisol. ¿Alcanzó a almorzar?'
 WHERE id = 'bbbbbbc2-0000-4000-8000-000000000002';

UPDATE contact_requests
   SET message = 'Hola Marisol, busco apoyo de día para mi mamá en San Pedro. ¿Tiene disponibilidad?'
 WHERE id = 'bbbbbbd3-0000-4000-8000-000000000001';

UPDATE caregiver_reviews
   SET comment = 'Marisol lleva seis meses con mi mamá. Puntual, registra todo en la app y avisa apenas pasa algo.'
 WHERE id = 'bbbbbbd4-0000-4000-8000-000000000001';

UPDATE invitations
   SET email = 'cuidadora@agecare.cl'
 WHERE id = 'bbbbbbc9-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------
-- 6. Coherencia entre la alerta y el dato de Luis
--    Su alerta activa dice "Saturación bajo el mínimo (86 %)", pero la última
--    lectura de saturación de la serie simulada era 91 %, dentro de su rango:
--    la tarjeta mostraba una alarma que el dato de al lado desmentía. Se
--    agrega la lectura que originó la alerta, con la hora real de ejecución (clock_timestamp y no now(): las
--    migraciones comparten transacción y now() es el mismo instante en que
--    termina la serie simulada, así que habría empate), para que alerta y dato
--    cuenten lo mismo. Solo si la alerta existe y no hay ya una lectura
--    bajo el mínimo en las últimas horas.
-- ---------------------------------------------------------------------
INSERT INTO vital_readings (patient_id, type, value, measured_at, source, meta)
SELECT '33333333-3333-4333-8333-333333333334', 'spo2', 86,
       clock_timestamp(), 'wearable', '{"origin":"simulator"}'::jsonb
 WHERE EXISTS (SELECT 1 FROM alerts
                WHERE id = 'aaaaaaa1-0000-4000-8000-000000000101'
                  AND status = 'active')
   -- Solo si la lectura más reciente contradice a la alerta (está en rango).
   AND (SELECT value FROM vital_readings
         WHERE patient_id = '33333333-3333-4333-8333-333333333334' AND type = 'spo2'
         ORDER BY measured_at DESC LIMIT 1) >= 88;

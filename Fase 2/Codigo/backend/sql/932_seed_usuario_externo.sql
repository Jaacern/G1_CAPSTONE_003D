-- AgeCare — Usuario externo para las pruebas
-- MIGRACION IDEMPOTENTE
--
-- Una cuenta valida que no pertenece al circulo de cuidado de ningun
-- paciente. Existe solo para poder probar la diferencia entre dos respuestas
-- que se confunden facil:
--
--   401  no hay sesion, o el token no vale
--   404  la sesion vale, pero esta persona no tiene nada que ver con este
--        paciente, y por eso el recurso ni se admite que exista
--
-- Esa segunda es la que protege los datos de un paciente de cualquier
-- usuario registrado, y sin una cuenta asi no se puede comprobar: las
-- pruebas firmaban un token para un id inexistente y el backend respondia
-- 401 antes de llegar a mirar el circulo, de modo que el 404 quedaba sin
-- verificar y la fuga, si aparecia, no la cazaba nadie.
--
-- Va en el sembrado de desarrollo y no dentro de las pruebas para que la
-- suite funcione sobre una base recien levantada con docker compose, sin
-- pasos a mano.
--
-- La contrasena es la misma del resto del sembrado. Desde 999 la crean y
-- la borran las propias pruebas (tests/_ajeno.py).

INSERT INTO users (id, email, password_hash, first_name, last_name, phone, locale)
VALUES ('eeeeeee1-0000-4000-8000-000000000001',
        'externo@agecare.cl',
        '$2b$12$PhFlUg1xEBTGKQuSYaBy.ODxdKlWAShWRiJxT0w85tC15kZaSNK/.',
        'Externo', 'Sin Circulo', '+56900000001', 'es')
ON CONFLICT (id) DO NOTHING;

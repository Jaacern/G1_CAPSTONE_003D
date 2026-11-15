-- AgeCare — Datos de demostracion (SOLO DESARROLLO)
-- 947_cuentas_demo.sql — Cuentas de prueba con correos neutros y una sola clave
-- MIGRACION IDEMPOTENTE
-- SEMILLA
-- Datos de ejemplo, no un cambio de esquema. Por eso no lleva revert
-- en sql/revertir/: deshacerla seria borrar datos de demostracion, que
-- es otra cosa que deshacer una migracion (RNF-24).
--
-- POR QUE
--   Las cuentas de prueba usaban correos y dominios sueltos y una clave
--   distinta a la del modo demo de la app. Quedan cinco cuentas, una por rol,
--   todas en @agecare.cl y con la misma clave que el modo demo: agecare123.
--
--     familiar@agecare.cl        familiar dueño de Elena y Luis
--     cuidadora@agecare.cl       cuidadora de Elena y Luis
--     doctora@agecare.cl         médica habilitada
--     adultomayor@agecare.cl     el adulto mayor (rol elder)
--     administrador@agecare.cl   personal de AgeCare (panel)
--
--   Los nombres completos quedan en 999_unico_circulo_demo.sql.
--
--   Las bases nuevas ya nacen asi desde los seeds. Esto alinea las bases que
--   se crearon antes: se cambian por id fijo, la doctora por su correo y el
--   administrador por ser la cuenta de personal que sembro 929. Si el correo
--   nuevo ya lo usa otra cuenta, esa fila no se toca.
--   En produccion estas cuentas se borran antes de salir.

-- El administrador de la demostracion nace AQUI, en la capa de datos de
-- ejemplo, no en la migracion de esquema 929 (de donde se saco para que una
-- credencial de clave conocida no corra en produccion). Misma clave demo que
-- el resto: agecare123. Guardado por correo para no duplicar si ya existe.
INSERT INTO users (email, password_hash, first_name, last_name, phone, locale, is_staff)
SELECT 'administrador@agecare.cl',
       '$2b$12$sOwnF0GBHVfW/6AuaTTIoez598bSRvAjjd.MhockXbT6sCX1.v4Xe',
       'Tomás', 'Bravo', '+56933334444', 'es', true
 WHERE NOT EXISTS (SELECT 1 FROM users WHERE lower(email) = 'administrador@agecare.cl');

-- La clave es el hash bcrypt de 'agecare123' (app.security.hash_password).
UPDATE users u
   SET email = c.new_email,
       password_hash = '$2b$12$sOwnF0GBHVfW/6AuaTTIoez598bSRvAjjd.MhockXbT6sCX1.v4Xe'
  FROM (VALUES
    ('familiar@agecare.cl',    '11111111-1111-4111-8111-111111111111'::uuid),
    ('cuidadora@agecare.cl',   '22222222-2222-4222-8222-222222222222'::uuid),
    ('adultomayor@agecare.cl', '99999999-9999-4999-8999-999999999999'::uuid)
  ) AS c(new_email, uid)
 WHERE u.id = c.uid
   AND NOT EXISTS (SELECT 1 FROM users o
                    WHERE lower(o.email) = c.new_email AND o.id <> u.id);

UPDATE users
   SET password_hash = '$2b$12$sOwnF0GBHVfW/6AuaTTIoez598bSRvAjjd.MhockXbT6sCX1.v4Xe'
 WHERE lower(email) IN ('doctora@agecare.cl', 'administrador@agecare.cl');

-- El administrador sembrado por 929 antes de que naciera con su correo nuevo.
UPDATE users u
   SET email = 'administrador@agecare.cl',
       password_hash = '$2b$12$sOwnF0GBHVfW/6AuaTTIoez598bSRvAjjd.MhockXbT6sCX1.v4Xe'
 WHERE u.is_staff
   AND u.first_name = 'Administracion' AND u.last_name = 'Alloxentric'
   AND NOT EXISTS (SELECT 1 FROM users o
                    WHERE lower(o.email) = 'administrador@agecare.cl' AND o.id <> u.id);

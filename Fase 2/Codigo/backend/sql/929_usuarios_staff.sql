-- AgeCare — Administracion
-- 929_usuarios_staff.sql — Marcar quien trabaja en Alloxentric
-- MIGRACION IDEMPOTENTE
--
-- Lleva la marca porque faltaba y eso rompia el panel de administracion
-- en toda base que ya existia: el volumen de Postgres solo corre los .sql
-- al crearse, asi que quien tenia la base levantada nunca recibio
-- is_staff, y sin esa columna el login del administrador falla. Todo lo
-- que hace este archivo se puede repetir sin dano: ADD COLUMN IF NOT
-- EXISTS, CREATE INDEX IF NOT EXISTS y un INSERT con ON CONFLICT.
--
-- EL PROBLEMA
--     El modelo no tenia forma de decir "esta persona es de la empresa".
--     Los cuatro roles que existen (family, caregiver, doctor, elder) viven
--     en patient_members y son roles DE UNA RELACION con un paciente. Son
--     la respuesta correcta a "que es esta persona para don Luis", y no
--     sirven para "quien puede cambiar los planes que se le venden a todo
--     el mundo", que no es una relacion con ningun paciente.
--
--     Sin esto, los planes solo se podian editar con SQL a mano.
--
-- POR QUE UNA COLUMNA Y NO UNA TABLA APARTE
--     Se evaluaron las dos. Una tabla staff_users separa del todo al
--     personal de la empresa de los usuarios de la aplicacion, que es mas
--     limpio conceptualmente, pero obliga a duplicar entera la cadena de
--     autenticacion: su propio login, su propio refresh, su propia
--     revocacion de sesiones, su propio hash de contrasena. Todo eso ya
--     existe y esta probado sobre users.
--
--     La columna reutiliza esa cadena completa. El costo es que una fila de
--     users puede ser las dos cosas a la vez, y se asume: en una empresa
--     chica es incluso esperable que quien administra los planes tambien
--     cuide a su propia madre con la aplicacion.
--
-- QUE NO ES
--     No es un permiso sobre expedientes. Un miembro del personal NO ve
--     pacientes por ser personal: para entrar a un expediente sigue
--     necesitando su fila en patient_members, igual que cualquiera. Esta
--     columna solo abre la administracion de planes y del catalogo.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS is_staff boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN users.is_staff IS
    'Personal de Alloxentric: puede administrar planes, funcionalidades, limites y precios. NO da acceso a ningun expediente; para eso sigue haciendo falta la membresia en patient_members.';

-- Indice parcial: el personal son unos pocos entre todos los usuarios, asi
-- que el indice solo los contiene a ellos y se mantiene diminuto.
CREATE INDEX IF NOT EXISTS ix_users_staff
    ON users (email)
    WHERE is_staff AND deleted_at IS NULL;

-- La cuenta de administracion de la demostracion (administrador@agecare.cl)
-- ya NO se siembra aqui. Plantar una credencial de clave conocida dentro de
-- una migracion de ESQUEMA -que corre en TODOS los entornos, produccion
-- incluida- era el hallazgo de la auditoria. Ahora nace en la capa de datos
-- de ejemplo, junto al resto de las cuentas demo, en 947_cuentas_demo.sql
-- (es un seed de datos de ejemplo, que se quita antes de salir a produccion).
-- Esta migracion
-- queda solo con el esquema (la columna is_staff y su indice).

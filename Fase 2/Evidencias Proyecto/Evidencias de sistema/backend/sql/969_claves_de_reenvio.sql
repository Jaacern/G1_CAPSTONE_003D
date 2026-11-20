-- MIGRACION IDEMPOTENTE
--
-- Claves de reenvio (RF-81).
--
-- La app guarda las acciones que no pudo mandar y las reintenta cuando vuelve
-- la senal. El problema no es el reintento, es que la app no siempre sabe si
-- el primer envio llego: la conexion se puede cortar justo despues de que el
-- servidor guardo la toma y antes de que la respuesta alcanzara a volver.
-- Desde el telefono ese caso es indistinguible de un envio que nunca llego.
--
-- Por eso la decision no se le deja a la app. Cada accion viaja con una clave
-- propia y el servidor recuerda que respuesta dio para esa clave. Si la clave
-- vuelve, devuelve la misma respuesta sin escribir nada. Asi un reintento no
-- deja dos tomas registradas ni dos mensajes en el chat.
--
-- La clave se guarda junto al usuario, el metodo y la ruta. El usuario, para
-- que nadie pueda pedir la respuesta de otro adivinando su clave. El metodo y
-- la ruta, para que una clave reusada por error en otra accion se note en vez
-- de devolver silenciosamente la respuesta equivocada.

CREATE TABLE IF NOT EXISTS idempotency_keys (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    idem_key      varchar(80) NOT NULL,
    method        varchar(10) NOT NULL,
    path          text        NOT NULL,
    status_code   smallint    NOT NULL,
    response_body jsonb       NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),

    -- Una clave por usuario. Es lo que impide el duplicado: si dos reenvios
    -- de la misma accion llegan a la vez, el segundo choca aqui y su
    -- transaccion entera se cae, incluida la escritura que traia.
    CONSTRAINT uq_idempotency_keys_usuario UNIQUE (user_id, idem_key),

    -- Solo se recuerdan respuestas buenas. Un error no se repite: si la
    -- accion fallo, el reintento tiene derecho a volver a intentarla.
    CONSTRAINT ck_idempotency_keys_status CHECK (status_code BETWEEN 200 AND 299)
);

-- Para el barrido por antiguedad.
CREATE INDEX IF NOT EXISTS ix_idempotency_keys_created
    ON idempotency_keys (created_at);

COMMENT ON TABLE idempotency_keys IS
    'Respuesta ya entregada para una clave de reenvio, para que un reintento '
    'de la app no duplique la accion (RF-81).';
COMMENT ON COLUMN idempotency_keys.idem_key IS
    'Clave que manda la app en la cabecera Idempotency-Key.';
COMMENT ON COLUMN idempotency_keys.response_body IS
    'Cuerpo exacto que se le respondio la primera vez, para devolverlo igual.';

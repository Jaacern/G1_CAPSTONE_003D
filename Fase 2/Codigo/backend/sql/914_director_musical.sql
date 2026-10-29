-- AgeCare — Director Musical
-- 914_director_musical.sql — Cierre de RF-66 y RF-67
--
-- Las tablas 810 y 811 las entregó el equipo y están bien construidas, pero
-- quedaron cortas frente a dos requisitos. Esto las completa con ALTER, sin
-- tocar sus archivos.
--
-- ===========================================================================
-- RF-66 · "Conservar las creaciones y sincronizarlas SIN DUPLICAR"
-- ===========================================================================
-- El audio se genera en el dispositivo del adulto mayor y se sube después. Si
-- se corta la señal a mitad de la subida, el dispositivo reintenta. Hoy nada
-- impide que cada reintento cree una fila nueva, así que la abuela termina con
-- cuatro copias de la misma canción y RF-66 no se cumple.
--
-- La solución es un identificador que genera el propio dispositivo antes de
-- subir, con UNIQUE. El segundo intento choca contra el motor y el reintento
-- se vuelve inofensivo. Es la misma idea que provider_event_id en
-- billing_events, que protege de los reintentos de la pasarela de pago.

ALTER TABLE music_creations ADD COLUMN IF NOT EXISTS client_uuid uuid;

-- Las creaciones que ya existan reciben uno, para poder exigirlo de aquí en
-- adelante sin perder lo cargado.
UPDATE music_creations SET client_uuid = gen_random_uuid() WHERE client_uuid IS NULL;

ALTER TABLE music_creations ALTER COLUMN client_uuid SET NOT NULL;
ALTER TABLE music_creations ALTER COLUMN client_uuid SET DEFAULT gen_random_uuid();

ALTER TABLE music_creations DROP CONSTRAINT IF EXISTS uq_music_creations_client;
ALTER TABLE music_creations ADD CONSTRAINT uq_music_creations_client UNIQUE (client_uuid);

COMMENT ON COLUMN music_creations.client_uuid IS
    'Identificador que genera el dispositivo antes de subir la creación. UNIQUE: si la subida se reintenta porque se cortó la señal, el motor rechaza el duplicado. Es lo que cumple el "sin duplicar" de RF-66.';

-- ===========================================================================
-- RF-67 · "Compartir creaciones por ENLACE SEGURO de escucha"
-- ===========================================================================
-- creation_shares solo permitía compartir con un usuario del sistema, porque
-- shared_with_user_id era NOT NULL. Pero el destinatario típico de RF-67 es la
-- nieta que vive lejos y no tiene cuenta en AgeCare. Con el modelo anterior,
-- dejarla escuchar obligaba a meterla al círculo de cuidado, o sea darle acceso
-- al expediente completo del paciente para que oyera una canción.
--
-- Ahora hay dos formas de compartir y un CHECK obliga a que sea exactamente
-- una: con un miembro del círculo, o por enlace con token.
--
-- El enlace sigue el mismo patrón de invitations y device_link_codes: se guarda
-- el hash y nunca el token, vence, y se puede revocar.

ALTER TABLE creation_shares ALTER COLUMN shared_with_user_id DROP NOT NULL;

ALTER TABLE creation_shares ADD COLUMN IF NOT EXISTS token_hash  varchar(64);
ALTER TABLE creation_shares ADD COLUMN IF NOT EXISTS expires_at  timestamptz;
ALTER TABLE creation_shares ADD COLUMN IF NOT EXISTS revoked_at  timestamptz;
ALTER TABLE creation_shares ADD COLUMN IF NOT EXISTS play_count  integer NOT NULL DEFAULT 0;
ALTER TABLE creation_shares ADD COLUMN IF NOT EXISTS last_played_at timestamptz;
ALTER TABLE creation_shares ADD COLUMN IF NOT EXISTS shared_by   uuid;

ALTER TABLE creation_shares DROP CONSTRAINT IF EXISTS fk_creation_shares_shared_by;
ALTER TABLE creation_shares ADD CONSTRAINT fk_creation_shares_shared_by
    FOREIGN KEY (shared_by) REFERENCES users(id) ON DELETE RESTRICT;

-- O se comparte con alguien del círculo, o se emite un enlace. Nunca las dos
-- cosas en la misma fila, y nunca ninguna.
ALTER TABLE creation_shares DROP CONSTRAINT IF EXISTS ck_creation_shares_destino;
ALTER TABLE creation_shares ADD CONSTRAINT ck_creation_shares_destino
    CHECK ((shared_with_user_id IS NOT NULL AND token_hash IS NULL)
        OR (shared_with_user_id IS NULL AND token_hash IS NOT NULL));

-- Un enlace sin vencimiento es un enlace para siempre. RF-67 habla de enlace
-- seguro, y lo que lo hace seguro es que caduca.
ALTER TABLE creation_shares DROP CONSTRAINT IF EXISTS ck_creation_shares_vigencia;
ALTER TABLE creation_shares ADD CONSTRAINT ck_creation_shares_vigencia
    CHECK (token_hash IS NULL OR expires_at IS NOT NULL);

ALTER TABLE creation_shares DROP CONSTRAINT IF EXISTS ck_creation_shares_reproducciones;
ALTER TABLE creation_shares ADD CONSTRAINT ck_creation_shares_reproducciones
    CHECK (play_count >= 0 AND (play_count = 0) = (last_played_at IS NULL));

ALTER TABLE creation_shares DROP CONSTRAINT IF EXISTS uq_creation_shares_token;
ALTER TABLE creation_shares ADD CONSTRAINT uq_creation_shares_token UNIQUE (token_hash);

-- Enlaces vigentes de una creación.
CREATE INDEX IF NOT EXISTS ix_creation_shares_enlaces
    ON creation_shares (music_creation_id, expires_at DESC)
    WHERE token_hash IS NOT NULL AND revoked_at IS NULL;

COMMENT ON TABLE creation_shares IS
    'Compartición de una creación musical, con un miembro del círculo o por enlace de escucha con token y vencimiento. El enlace existe para que alguien sin cuenta pueda escuchar sin entrar al expediente. RF-67.';
COMMENT ON COLUMN creation_shares.shared_with_user_id IS
    'Miembro del círculo con quien se comparte. Nulo cuando se compartió por enlace.';
COMMENT ON COLUMN creation_shares.token_hash IS
    'Hash del token del enlace de escucha. El token en claro no se guarda nunca. Nulo cuando se compartió con un usuario.';
COMMENT ON COLUMN creation_shares.expires_at IS
    'Vencimiento del enlace. Obligatorio cuando hay token: un enlace sin caducidad no es un enlace seguro.';
COMMENT ON COLUMN creation_shares.revoked_at IS
    'Momento en que se anuló el enlace antes de su vencimiento.';
COMMENT ON COLUMN creation_shares.play_count IS
    'Cuántas veces se escuchó por este enlace.';
COMMENT ON COLUMN creation_shares.last_played_at IS
    'Última reproducción. Va de la mano con play_count.';
COMMENT ON COLUMN creation_shares.shared_by IS
    'Quién compartió la creación.';

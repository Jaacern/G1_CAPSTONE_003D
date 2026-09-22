-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla de refresh tokens

CREATE TABLE refresh_tokens(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    family_id uuid NOT NULL,
    token_hash varchar(64) NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    revoked_reason varchar(20),
    created_at timestamptz NOT NULL DEFAULT now(),


--hacemos que que los datos tengan una forma coherente

    CONSTRAINT ck_refresh_tokens_expires
        CHECK (expires_at > created_at),
    CONSTRAINT ck_refresh_tokens_revoked_reason
        CHECK(revoked_reason IS NULL OR revoked_reason IN
                ('rotated', 'logout', 'reuse_detected','password_reset','account_disabled')),
    CONSTRAINT ck_refresh_tokens_revoked_pair
        CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL)),
    CONSTRAINT fk_refresh_tokens_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

--Busqueda de cada renovacion dos sesiopnes no pueden compartir tokens
CREATE UNIQUE INDEX ux_refresh_tokens_hash
    ON refresh_tokens (token_hash);

--anulamos todas las sesiones de el usuario
-- solo indexa las vigentes
CREATE INDEX ix_refresh_tokens_user_active
    ON refresh_tokens (user_id) WHERE revoked_at IS NULL;

--anulamos una familia completa al detectar utilizacion
CREATE INDEX ix_refresh_tokens_family
    ON refresh_tokens (family_id);

--un job de limpieza de los ya expirados

CREATE INDEX ix_refresh_tokens_expires
    ON refresh_tokens (expires_at);


COMMENT ON TABLE  refresh_tokens IS
    'Sesiones activas. Guarda el hash del refresh token para poder revocarlo desde el servidor, algo que el access token (JWT sin estado) no permite.';
COMMENT ON COLUMN refresh_tokens.id IS
    'Identificador interno del registro de sesión.';
COMMENT ON COLUMN refresh_tokens.user_id IS
    'Dueño de la sesión. ON DELETE CASCADE: un token no tiene valor sin su usuario.';
COMMENT ON COLUMN refresh_tokens.family_id IS
    'Agrupa todos los tokens nacidos del mismo inicio de sesión. Permite revocar una sola sesión ante reutilización, sin desconectar los demás dispositivos (ticket AGE-104).';
COMMENT ON COLUMN refresh_tokens.token_hash IS
    'SHA-256 en hexadecimal del token. Nunca el token en claro. Hash rápido a propósito: el token es aleatorio de 256 bits, no necesita resistencia a fuerza bruta.';
COMMENT ON COLUMN refresh_tokens.expires_at IS
    'Vencimiento. 30 días desde la emisión, según la Documentación de Seguridad.';
COMMENT ON COLUMN refresh_tokens.revoked_at IS
    'Momento de la revocación. NULL = vigente.';
COMMENT ON COLUMN refresh_tokens.revoked_reason IS
    'Motivo: rotated | logout | reuse_detected | password_reset | account_disabled.';
COMMENT ON COLUMN refresh_tokens.created_at IS
    'Momento de emisión del token.';

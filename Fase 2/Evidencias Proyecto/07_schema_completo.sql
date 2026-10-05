-- ============================================================================
-- AgeCare - Esquema completo consolidado (modelo de datos definitivo)
-- Proyecto APT - Capstone PTY4614 - DUOC UC
-- PostgreSQL 16 - Modelo relacional normalizado hasta 2FN
--
-- Consolida los scripts de esquema del directorio sql/ en orden de
-- dependencias de claves foraneas. El seed (900_seed_dev.sql) va aparte.
-- 24 tablas de negocio + funciones y triggers.
-- ============================================================================


-- ============================================================================
-- Fuente: 001_base.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION set_updated_at() IS
    'Trigger compartido: actualiza updated_at en cada UPDATE.';



-- ============================================================================
-- Fuente: 101_users.sql
-- ============================================================================
-- AgeCare — Bloque 1: Identidad y acceso


-- AgeCare — Bloque 1: Identidad y acceso
-- Corrección 2FN: full_name dividido en first_name + last_name (1FN: atomicidad).
-- full_name se mantiene como columna GENERATED para compatibilidad con la API v1.

CREATE TABLE users(
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    email         varchar(254) NOT NULL,
    password_hash varchar(255) NOT NULL,
    first_name    varchar(60)  NOT NULL,
    last_name     varchar(60)  NOT NULL,
    -- Columna generada: solo lectura, compatible con la API y búsquedas de texto.
    full_name     varchar(121) GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
    phone         varchar(16),
    avatar_url    text,
    locale        varchar(5)   NOT NULL DEFAULT 'es',
    is_active     boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    deleted_at    timestamptz,

    CONSTRAINT ck_users_locale
        CHECK (locale IN ('es', 'en')),
    CONSTRAINT ck_users_first_name_min
        CHECK (char_length(first_name) >= 1),
    CONSTRAINT ck_users_last_name_min
        CHECK (char_length(last_name) >= 1)
);

-- Un mismo correo no puede usarse dos veces, aunque se escriba distinto en mayúsculas.
-- Ademas aceleramos las consultas en el Login

CREATE UNIQUE INDEX ux_users_email_lower ON users (lower(email));


-- updated_at se mantiene solo: cada vez que una fila se actualice,
-- antes de guardarla se pondrá updated_at en la hora de la modificación.
CREATE TRIGGER tg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

--diccionario de datos en español, dentro de la propia bd para DUOC
COMMENT ON TABLE  users IS
    'Cuentas de usuario. El rol NO vive acá: un usuario puede tener roles distintos sobre distintos pacientes, y eso se resuelve en patient_members.';
    COMMENT ON COLUMN users.id IS
    'Identificador interno. UUID generado por la base.';
COMMENT ON COLUMN users.avatar_url IS
    'URL de la foto de perfil. Opcional.';
COMMENT ON COLUMN users.created_at IS
    'Fecha de creación del registro.';
COMMENT ON COLUMN users.updated_at IS
    'Fecha de última modificación. La mantiene el trigger tg_users_updated_at.';
COMMENT ON COLUMN users.email IS
    'Correo de acceso. Unicidad garantizada por ux_users_email_lower, sin distinguir mayúsculas.';
COMMENT ON COLUMN users.password_hash IS
    'Hash argon2 o bcrypt. Nunca la contraseña en claro. Largo holgado porque el algoritmo aún no está decidido.';
COMMENT ON COLUMN users.full_name IS
    'Nombre completo, 2 a 120 caracteres. Se evaluó separarlo y se mantuvo unido por contrato con la API.';
COMMENT ON COLUMN users.phone IS
    'Teléfono en formato E.164, opcional.';
COMMENT ON COLUMN users.locale IS
    'Idioma preferido de la interfaz. es | en.';
COMMENT ON COLUMN users.is_active IS
    'false = cuenta desactivada por soporte. Ticket AGE-208.';
COMMENT ON COLUMN users.deleted_at IS
    'Baja lógica para la eliminación de cuenta. Ticket AGE-1007, requisito de Google Play. NULL = vigente.';



-- ============================================================================
-- Fuente: 102_refresh_tokens.sql
-- ============================================================================
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


-- ============================================================================
-- Fuente: 103_push_devices.sql
-- ============================================================================
-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 3 de 6: push_devices

CREATE TABLE push_devices(
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
user_id uuid NOT NULL,
push_token varchar(255) NOT NULL,
platform varchar(10) NOT NULL,
is_active boolean NOT NULL DEFAULT true,
last_seen_at timestamptz NOT NULL DEFAULT now(),
created_at timestamptz  NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_push_devices_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT ck_push_devices_platform
    CHECK (platform IN ('ios', 'android', 'web'))
);

--Unico en toda la tabla no por usuario
--Esto es lo que el telefono cambie de dueño
CREATE UNIQUE INDEX ux_push_devices_token
    ON push_devices (push_token);

--Esto es lo que manda la alerta a los aparatos activos
CREATE INDEX ix_push_devices_user_active
    ON push_devices (user_id) WHERE is_active;

COMMENT ON TABLE  push_devices IS
    'Aparatos registrados para recibir notificaciones push. Sin esto, las alertas no llegan a nadie.';
COMMENT ON COLUMN push_devices.user_id IS
    'Dueño actual del aparato. Puede cambiar si otra persona inicia sesión en el mismo teléfono.';
COMMENT ON COLUMN push_devices.push_token IS
    'Código que entrega FCM o APNs. Identifica la instalación de la app, no a la persona. Único en toda la tabla.';
COMMENT ON COLUMN push_devices.platform IS
    'Sistema del aparato: ios | android | web.';
COMMENT ON COLUMN push_devices.is_active IS
    'false = se cerró sesión en ese aparato o el token dejó de ser válido. Se deja de enviar, pero no se borra.';
COMMENT ON COLUMN push_devices.last_seen_at IS
    'Última vez que la app confirmó este aparato. Sirve para limpiar los abandonados.';
COMMENT ON COLUMN push_devices.created_at IS
    'Primer registro del aparato.';
COMMENT ON COLUMN push_devices.updated_at IS
    'Última modificación. La mantiene el trigger.';


CREATE TRIGGER tg_push_devices_updated_at
    BEFORE UPDATE ON push_devices
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON COLUMN push_devices.updated_at IS
    'Última modificación. Trigger tg_push_devices_updated_at agregado en corrección 2FN: faltaba en la versión original.';


-- ============================================================================
-- Fuente: 104_patients.sql
-- ============================================================================
-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 4 de 6: patients
--
-- Correcciones 2FN aplicadas:
--   · full_name dividido en first_name + last_name (1FN: atomicidad)
--   · full_name se mantiene como columna GENERATED para compatibilidad con API y búsquedas
--   · conditions eliminado → tabla patient_conditions (1FN: no grupos repetidos)
--   · rut_dv documentado como dato derivado (módulo 11 de rut_number)

CREATE TABLE patients (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),

    -- 1FN: nombre y apellido son atributos distintos
    first_name  varchar(60)  NOT NULL,
    last_name   varchar(60)  NOT NULL,
    -- Columna calculada para compatibilidad con la API y búsquedas de texto
    full_name   varchar(121) GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,

    -- RUT: rut_dv es derivable de rut_number (módulo 11).
    -- Se almacena por conveniencia de validación; no es dato independiente.
    rut_number  integer,
    rut_dv      char(1),

    birth_date  date         NOT NULL,
    sex         char(1)      NOT NULL,
    photo_url   text,
    timezone    varchar(50)  NOT NULL DEFAULT 'America/Santiago',
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    deleted_at  timestamptz,

    CONSTRAINT ck_patients_first_name_min
        CHECK (char_length(first_name) >= 1),
    CONSTRAINT ck_patients_last_name_min
        CHECK (char_length(last_name) >= 1),
    CONSTRAINT ck_patients_sex
        CHECK (sex IN ('M','F','O')),
    CONSTRAINT ck_patients_birth_date
        CHECK (birth_date > '1900-01-01' AND birth_date <= CURRENT_DATE),
    CONSTRAINT ck_patients_rut_pair
        CHECK ((rut_number IS NULL) = (rut_dv IS NULL)),
    CONSTRAINT ck_patients_rut_number
        CHECK (rut_number IS NULL OR rut_number BETWEEN 1000000 AND 99999999),
    CONSTRAINT ck_patients_rut_dv
        CHECK (rut_dv IS NULL OR rut_dv ~ '^[0-9K]$')
);

-- Un RUT identifica a una persona. Solo entre los vigentes.
CREATE UNIQUE INDEX ux_patients_rut
    ON patients (rut_number) WHERE deleted_at IS NULL AND rut_number IS NOT NULL;

-- Búsqueda por nombre completo.
CREATE INDEX ix_patients_full_name
    ON patients (lower(full_name)) WHERE deleted_at IS NULL;

CREATE TRIGGER tg_patients_updated_at
    BEFORE UPDATE ON patients
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  patients IS
    'Adultos mayores de los que se lleva expediente. NO es un usuario: el paciente puede no tener cuenta. El vínculo entre personas y pacientes vive en patient_members.';
COMMENT ON COLUMN patients.first_name IS
    'Nombre(s) del adulto mayor. Separado de last_name para ordenar por apellido y generar saludos formales. 1FN: atomicidad.';
COMMENT ON COLUMN patients.last_name IS
    'Apellido(s) del adulto mayor. 1FN: atributo distinto de first_name.';
COMMENT ON COLUMN patients.full_name IS
    'Columna generada (first_name || last_name). Solo lectura. Mantiene compatibilidad con la API v1 y facilita búsquedas de texto completo.';
COMMENT ON COLUMN patients.rut_number IS
    'Número del RUT sin puntos ni dígito verificador. Entero para evitar duplicados por formato.';
COMMENT ON COLUMN patients.rut_dv IS
    'Dígito verificador (0-9 o K). Derivable de rut_number por módulo 11. Se almacena por conveniencia de validación, no como dato independiente.';
COMMENT ON COLUMN patients.birth_date IS
    'Fecha de nacimiento. La edad se calcula: date_part(''year'', age(birth_date)).';
COMMENT ON COLUMN patients.sex IS
    'M = masculino, F = femenino, O = otro.';
COMMENT ON COLUMN patients.timezone IS
    'Zona horaria IANA. Base del cálculo de horarios de medicación (RF-32). Por defecto America/Santiago.';
COMMENT ON COLUMN patients.deleted_at IS
    'Baja lógica. El expediente clínico nunca se borra físicamente.';


-- ─────────────────────────────────────────────────────────────────
-- patient_conditions
-- Normalización 1FN: reemplaza la columna conditions jsonb de patients.
-- Cada condición médica es una entidad con su propio ciclo de vida.
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE patient_conditions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id   uuid        NOT NULL,
    condition    varchar(80) NOT NULL,
    diagnosed_at date,
    created_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_patient_conditions_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
    CONSTRAINT uq_patient_condition
        UNIQUE (patient_id, condition),
    CONSTRAINT ck_patient_condition_min
        CHECK (char_length(condition) >= 2)
);

CREATE INDEX ix_patient_conditions_patient
    ON patient_conditions (patient_id);

COMMENT ON TABLE  patient_conditions IS
    'Condiciones médicas del paciente. Normalización 1FN: reemplaza el arreglo JSON conditions que vivía en patients. Permite filtrar pacientes por padecimiento y agregar fecha de diagnóstico.';
COMMENT ON COLUMN patient_conditions.condition IS
    'Código o descripción del padecimiento (ej. hipertension, diabetes_tipo_2).';
COMMENT ON COLUMN patient_conditions.diagnosed_at IS
    'Fecha de diagnóstico. Opcional; no estaba disponible en el modelo anterior.';


-- ============================================================================
-- Fuente: 105_patient_members.sql
-- ============================================================================
-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 5 de 6: patient_members

CREATE TABLE patient_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid NOT NULL,
    user_id    uuid NOT NULL,
    role varchar(10) NOT NULL,
    is_owner boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    removed_at timestamptz,

CONSTRAINT fk_patient_members_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_patient_members_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT uq_patient_members_pair
    UNIQUE (patient_id, user_id),
CONSTRAINT ck_patient_members_role
    CHECK (role IN ('family','caregiver','doctor','elder')),
CONSTRAINT ck_patient_members_owner_is_family
    CHECK (NOT is_owner OR role = 'family')
);

-- Como máximo un administrador por paciente.
-- No puede garantizar que haya al menos uno: eso lo cuida la aplicación.
CREATE UNIQUE INDEX ux_patient_members_owner
    ON patient_members (patient_id) WHERE is_owner;

-- "¿Qué pacientes puedo ver?"
-- de toda la plataforma: se ejecuta antes que casi cualquier otra cosa.
CREATE INDEX ix_patient_members_user
    ON patient_members (user_id) WHERE removed_at IS NULL;

CREATE TRIGGER tg_patient_members_updated_at
    BEFORE UPDATE ON patient_members
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  patient_members IS
    'Vínculo entre usuarios y pacientes, con el rol de cada uno. Es el centro del control de acceso: ninguna consulta al expediente se ejecuta sin verificarla primero.';
COMMENT ON COLUMN patient_members.role IS
    'Rol DE LA RELACIÓN, no de la persona: family | caregiver | doctor | elder. El mismo usuario puede tener roles distintos sobre pacientes distintos.';
COMMENT ON COLUMN patient_members.is_owner IS
    'Familiar administrador del paciente. Lo crea el endpoint 4.1 y no puede ser eliminado (endpoint 4.8). Solo un rol family puede serlo.';
COMMENT ON COLUMN patient_members.removed_at IS
    'Baja del círculo de cuidado. Se conserva la fila porque el endpoint 14.4 exige saber quién estuvo alguna vez en el círculo para validar las reseñas.';


-- ============================================================================
-- Fuente: 106_invitations.sql
-- ============================================================================
-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla 6 de 6: invitations

CREATE TABLE invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid NOT NULL,
    email varchar(320) NOT NULL,
    role varchar(10)  NOT NULL,
    token_hash varchar(64)  NOT NULL,
    invited_by uuid NOT NULL,
    expires_at timestamptz NOT NULL,
    accepted_at timestamptz,
    accepted_by uuid,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_invitations_patient
    FOREIGN KEY (patient_id)  REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_invitations_invited_by
    FOREIGN KEY (invited_by)  REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT fk_invitations_accepted_by
    FOREIGN KEY (accepted_by) REFERENCES users(id) ON DELETE SET NULL,
CONSTRAINT ck_invitations_role
    CHECK (role IN ('family','caregiver','doctor','elder')),
CONSTRAINT ck_invitations_expires
    CHECK (expires_at > created_at),
CONSTRAINT ck_invitations_accepted_pair
    CHECK ((accepted_at IS NULL) = (accepted_by IS NULL)),
CONSTRAINT ck_invitations_not_both
    CHECK (NOT (accepted_at IS NOT NULL AND revoked_at IS NOT NULL))
);

-- Búsqueda al aceptar la invitación.
CREATE UNIQUE INDEX ux_invitations_token
    ON invitations (token_hash);

-- Una sola invitación viva por correo y paciente.
-- Reenviar actualiza la fila existente, no crea otra.
CREATE UNIQUE INDEX ux_invitations_pending
    ON invitations (patient_id, lower(email))
    WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- Listar las invitaciones de un paciente (endpoint 4.7).
CREATE INDEX ix_invitations_patient
    ON invitations (patient_id);

CREATE TRIGGER tg_invitations_updated_at
    BEFORE UPDATE ON invitations
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  invitations IS
    'Invitaciones al círculo de cuidado. Se invita a un CORREO, no a un usuario: el invitado puede no tener cuenta todavía (endpoints 4.6 y 3.1).';
COMMENT ON COLUMN invitations.email IS
    'Correo del invitado. Sin clave foránea a users porque puede no existir aún. La unicidad ignora mayúsculas (ver ux_invitations_pending).';
COMMENT ON COLUMN invitations.token_hash IS
    'SHA-256 del token de invitación. Nunca en claro: ese token da acceso a un expediente clínico.';
COMMENT ON COLUMN invitations.invited_by IS
    'Quién envió la invitación. Normalmente el familiar administrador.';
COMMENT ON COLUMN invitations.expires_at IS
    'Vencimiento. 7 días desde el envío, según el ticket AGE-202.';
COMMENT ON COLUMN invitations.accepted_by IS
    'Usuario que aceptó. ON DELETE SET NULL: si borra su cuenta, la invitación sigue siendo parte de la historia del paciente.';
COMMENT ON COLUMN invitations.revoked_at IS
    'Invitación anulada por el administrador antes de ser aceptada (ticket AGE-207).';


-- ============================================================================
-- Fuente: 107_audit_log.sql
-- ============================================================================
-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla transversal: audit_log (depende de users y patients)
--
-- Análisis de realidad (RNF-14 "Trazabilidad clínica"):
--   En un sistema de salud, el dato clínico no basta con guardarse: debe poder
--   responder QUIÉN hizo QUÉ, SOBRE QUÉ y CUÁNDO, de forma inmutable. Sin esto,
--   un UPDATE puede alterar una dosis o un umbral sin dejar rastro del valor
--   anterior, lo que es inaceptable cuando hay responsabilidad sobre un paciente.
--
--   Esta tabla es APPEND-ONLY: nunca se actualiza ni se borra. Registra tanto
--   accesos de lectura a expedientes (RNF-14) como cambios de estado sensibles
--   (p. ej. registrar/editar una dosis, resolver una alerta). La inmutabilidad
--   se refuerza con un trigger que bloquea UPDATE y DELETE.

CREATE TABLE audit_log (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Quién ejecutó la acción. SET NULL si la cuenta se elimina: el hecho
    -- auditado no desaparece aunque el usuario ya no exista.
    actor_user_id uuid,
    -- Acción realizada: verbo normalizado del dominio.
    action      varchar(40) NOT NULL,
    -- Entidad afectada (tabla lógica) y su identificador.
    entity_type varchar(40) NOT NULL,
    entity_id   uuid,
    -- Paciente sobre cuyo expediente ocurrió la acción (si aplica), para
    -- reconstruir "quién accedió al expediente de X".
    patient_id  uuid,
    -- Estado anterior y nuevo, para cambios (jsonb de atributos variables:
    -- aquí el jsonb es intencional, es un registro de auditoría heterogéneo).
    old_value   jsonb,
    new_value   jsonb,
    -- Contexto técnico de la petición.
    ip_address  inet,
    user_agent  varchar(300),
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_audit_log_actor
        FOREIGN KEY (actor_user_id) REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT fk_audit_log_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE SET NULL,
    CONSTRAINT ck_audit_log_action
        CHECK (action IN (
            'view_record','create','update','delete',
            'dose_log','alert_ack','alert_resolve','sos_trigger',
            'threshold_update','member_add','member_remove','login'
        ))
);

-- Reconstruir el historial de acceso a un expediente (RNF-14).
CREATE INDEX ix_audit_log_patient
    ON audit_log (patient_id, created_at DESC);

-- Auditar la actividad de un usuario.
CREATE INDEX ix_audit_log_actor
    ON audit_log (actor_user_id, created_at DESC);

-- Inmutabilidad: la auditoría no se edita ni se borra.
CREATE OR REPLACE FUNCTION audit_log_block_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_log es inmutable: no se permite % ', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_audit_log_no_update
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW
    EXECUTE FUNCTION audit_log_block_mutation();

COMMENT ON TABLE  audit_log IS
    'Registro inmutable (append-only) de accesos y cambios sobre datos clínicos. Cumple RNF-14 (trazabilidad clínica). Un trigger bloquea UPDATE y DELETE: la evidencia de auditoría no se puede alterar.';
COMMENT ON COLUMN audit_log.actor_user_id IS
    'Quién ejecutó la acción. ON DELETE SET NULL: el hecho auditado sobrevive a la cuenta.';
COMMENT ON COLUMN audit_log.action IS
    'Verbo del dominio: view_record (lectura de expediente), dose_log, alert_ack, etc.';
COMMENT ON COLUMN audit_log.old_value IS
    'Estado anterior del recurso en un cambio. jsonb INTENCIONAL: la auditoría registra entidades heterogéneas.';
COMMENT ON COLUMN audit_log.new_value IS
    'Estado nuevo del recurso en un cambio.';


-- ============================================================================
-- Fuente: 108_system_parameters.sql
-- ============================================================================
-- AgeCare — Bloque 1: Identidad y acceso
-- Tabla transversal: system_parameters (depende de users para updated_by)
--
-- Análisis de realidad:
--   Varios umbrales de negocio estaban implícitos en el código del worker
--   (p. ej. "2 horas sin datos del wearable", "30 minutos de deduplicación de
--   alertas", "4 horas máximo de postergación"). Un parámetro de negocio NO
--   debe vivir solo en el código: debe ser configurable, auditable y versionable
--   sin un redespliegue. Esta tabla centraliza esos valores como fuente única.
--
--   Es un catálogo clave-valor tipado. El valor se guarda como texto y la columna
--   value_type indica cómo interpretarlo, de modo que la tabla sirva para enteros,
--   intervalos o banderas sin cambiar su estructura.

CREATE TABLE system_parameters (
    key          varchar(60)  PRIMARY KEY,
    value        varchar(120) NOT NULL,
    value_type   varchar(20)  NOT NULL DEFAULT 'int',
    description  varchar(300) NOT NULL,
    updated_by   uuid,
    updated_at   timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_system_parameters_user
        FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT ck_system_parameters_type
        CHECK (value_type IN ('int','minutes','hours','decimal','bool','text'))
);

CREATE TRIGGER tg_system_parameters_updated_at
    BEFORE UPDATE ON system_parameters
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Valores por defecto: los umbrales que antes estaban hardcodeados.
INSERT INTO system_parameters (key, value, value_type, description) VALUES
    ('wearable_offline_minutes', '120', 'minutes',
     'Minutos sin sincronizar tras los cuales el wearable se considera sin datos y se genera alerta wearable_offline (Anexo B).'),
    ('alert_dedup_minutes', '30', 'minutes',
     'Ventana en la que no se repite una alerta por la misma condición (dedup_key).'),
    ('dose_postpone_max_hours', '4', 'hours',
     'Máximo de horas que una toma puede posponerse respecto de su hora programada.'),
    ('alert_escalation_minutes', '15', 'minutes',
     'Minutos sin atención tras los cuales una alerta crítica escala a los siguientes contactos (RF-52).'),
    ('session_access_minutes', '30', 'minutes',
     'Vigencia del access token (RNF-11).'),
    ('session_refresh_days', '30', 'int',
     'Vigencia del refresh token rotatorio (RNF-11).'),
    ('invitation_ttl_days', '7', 'int',
     'Vigencia de una invitación al círculo de cuidado.'),
    ('file_link_ttl_minutes', '15', 'minutes',
     'Vigencia de los enlaces firmados de subida/descarga de archivos (RNF-13).');

COMMENT ON TABLE  system_parameters IS
    'Catálogo clave-valor de parámetros de negocio configurables (umbrales de alertas, vigencias de tokens, ventanas de tiempo). Centraliza valores que antes vivían en el código; configurables y auditables sin redespliegue.';
COMMENT ON COLUMN system_parameters.value_type IS
    'Interpretación del valor: int | minutes | hours | decimal | bool | text.';
COMMENT ON COLUMN system_parameters.updated_by IS
    'Último administrador que modificó el parámetro. Trazabilidad del cambio de configuración.';


-- ============================================================================
-- Fuente: 200_vital_types.sql
-- ============================================================================
-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 0 de 3: vital_types  (catálogo)
--
-- Corrección 2FN:
--   · Centraliza el dominio de tipos de vitales que antes estaba duplicado
--     como CHECK idéntico en vital_readings y vital_thresholds.
--   · Agrega metadatos (unidad, si admite valor secundario) que antes vivían
--     hardcodeados en el código Python (dict UNITS en vitals.py).

CREATE TABLE vital_types (
    code          varchar(16)  PRIMARY KEY,
    label         varchar(60)  NOT NULL,
    unit          varchar(10)  NOT NULL DEFAULT '',
    has_secondary boolean      NOT NULL DEFAULT false,

    CONSTRAINT ck_vital_types_code_min
        CHECK (char_length(code) >= 2)
);

INSERT INTO vital_types (code, label, unit, has_secondary) VALUES
    ('heart_rate',    'Frecuencia cardíaca', 'bpm',    false),
    ('spo2',          'Saturación O₂',       '%',      false),
    ('sleep',         'Sueño',               'h',      false),
    ('steps',         'Pasos',               'pasos',  false),
    ('sedentary_min', 'Tiempo sedentario',   'min',    false),
    ('fall_event',    'Evento de caída',     '',       false),
    ('blood_pressure','Presión arterial',    'mmHg',   true),
    ('temperature',   'Temperatura',         '°C',     false),
    ('glucose',       'Glucosa',             'mg/dL',  false);

COMMENT ON TABLE  vital_types IS
    'Catálogo de tipos de signos vitales. Fuente única de verdad: reemplaza los CHECK duplicados en vital_readings y vital_thresholds. Agregar un nuevo tipo aquí lo habilita automáticamente en todo el sistema.';
COMMENT ON COLUMN vital_types.code IS
    'Identificador corto usado en la API y en las tablas de mediciones.';
COMMENT ON COLUMN vital_types.unit IS
    'Unidad de presentación. Reemplaza el dict UNITS hardcodeado en vitals.py.';
COMMENT ON COLUMN vital_types.has_secondary IS
    'true solo para blood_pressure (sistólica + diastólica). Usado por el CHECK ck_vital_readings_secondary.';


-- ============================================================================
-- Fuente: 201_wearables.sql
-- ============================================================================
--Bloque 2, vitals y wearable
-- Tabla 1 de 3: wearables

CREATE TABLE wearables (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid NOT NULL,
    provider varchar(20) NOT NULL DEFAULT 'simulator',
    serial_number varchar(64) NOT NULL,
    model varchar(60),
    battery_pct smallint,
    last_sync_at timestamptz,
    unlinked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_wearables_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT ck_wearables_provider
    CHECK (provider IN ('simulator','healthkit','health_connect','garmin','whoop')),
CONSTRAINT ck_wearables_battery
    CHECK (battery_pct IS NULL OR battery_pct BETWEEN 0 AND 100),
CONSTRAINT ck_wearables_unlinked
    CHECK (unlinked_at IS NULL OR unlinked_at >= created_at)
);

-- Un solo aparato vigente por paciente.
CREATE UNIQUE INDEX ux_wearables_patient_active
    ON wearables (patient_id) WHERE unlinked_at IS NULL;

-- El mismo aparato no puede estar vinculado a dos pacientes a la vez,
-- pero sí puede reutilizarse si se desvincula.
CREATE UNIQUE INDEX ux_wearables_serial_active
    ON wearables (provider, serial_number) WHERE unlinked_at IS NULL;

-- Para el vigilante que detecta wearables sin datos (Anexo B).
CREATE INDEX ix_wearables_last_sync
    ON wearables (last_sync_at) WHERE unlinked_at IS NULL;

CREATE TRIGGER tg_wearables_updated_at
    BEFORE UPDATE ON wearables
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  wearables IS
    'Dispositivo vestible vinculado a un paciente. Guarda el aparato y su estado; las mediciones viven en vital_readings.';
COMMENT ON COLUMN wearables.provider IS
    'Origen de los datos: simulator (v1 del plan) | healthkit | health_connect | garmin | whoop, vía Spike API.';
COMMENT ON COLUMN wearables.serial_number IS
    'Número de serie del aparato. Único junto al proveedor, y solo entre los vinculados: un reloj desvinculado puede asignarse a otro paciente.';
COMMENT ON COLUMN wearables.battery_pct IS
    'Nivel de batería, 0 a 100. NULL si el aparato aún no ha reportado (RF-16).';
COMMENT ON COLUMN wearables.last_sync_at IS
    'Última medición recibida. Base de la alerta wearable_offline: sin datos por más de 2 horas (Anexo B). NO se guarda un estado "conectado": se calcula comparando con la hora actual.';
COMMENT ON COLUMN wearables.unlinked_at IS
    'Desvinculación. NULL = vigente. Se conserva la fila para mantener el historial de aparatos del paciente.';


-- ============================================================================
-- Fuente: 202_vital_readings.sql
-- ============================================================================
-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 2 de 3: vital_readings  (PARTICIONADA POR MES)
--
-- Correcciones 2FN aplicadas:
--   · CHECK de type eliminado → FK a vital_types.code (catálogo centralizado)
--   · PK compuesta (id, measured_at): excepción técnica documentada.
--     measured_at está en la PK únicamente porque PostgreSQL exige que la columna
--     de particionamiento forme parte de la clave primaria. Los atributos dependen
--     solo de id, no de (id, measured_at). Esto viola 2FN en sentido estricto;
--     se acepta como concesión técnica del motor de particionamiento (RNF-07).

CREATE TABLE vital_readings (
    id              uuid          NOT NULL DEFAULT gen_random_uuid(),
    patient_id      uuid          NOT NULL,
    -- FK a vital_types: fuente única de verdad para tipos válidos
    type            varchar(16)   NOT NULL,
    value           numeric(8,2)  NOT NULL,
    value_secondary numeric(8,2),
    measured_at     timestamptz   NOT NULL,
    source          varchar(10)   NOT NULL,
    meta            jsonb,
    created_at      timestamptz   NOT NULL DEFAULT now(),

    -- EXCEPCIÓN 2FN DOCUMENTADA:
    -- La PK (id, measured_at) es requerida por PostgreSQL para tablas particionadas
    -- por rango (PARTITION BY RANGE). En el modelo relacional puro la PK debería
    -- ser solo id; measured_at se agrega exclusivamente por restricción del motor.
    -- Todos los atributos dependen funcionalmente de id, no de measured_at.
    CONSTRAINT pk_vital_readings
        PRIMARY KEY (id, measured_at),

    CONSTRAINT uq_vital_readings_natural
        UNIQUE (patient_id, type, measured_at, source),

    CONSTRAINT fk_vital_readings_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,

    -- FK al catálogo: reemplaza el CHECK de lista duplicada
    CONSTRAINT fk_vital_readings_type
        FOREIGN KEY (type) REFERENCES vital_types(code),

    CONSTRAINT ck_vital_readings_source
        CHECK (source IN ('wearable','manual')),
    -- value_secondary solo es válido para blood_pressure
    CONSTRAINT ck_vital_readings_secondary
        CHECK (value_secondary IS NULL OR type = 'blood_pressure'),
    -- Cordura de datos: ningún signo vital humano es negativo y hay un techo
    -- físicamente imposible. Los umbrales clínicos finos por paciente viven en
    -- vital_thresholds; este CHECK solo evita basura evidente (p. ej. FC = 9000).
    CONSTRAINT ck_vital_readings_value_sane
        CHECK (value >= 0 AND value <= 100000),
    CONSTRAINT ck_vital_readings_secondary_sane
        CHECK (value_secondary IS NULL OR (value_secondary >= 0 AND value_secondary <= 100000))

) PARTITION BY RANGE (measured_at);

-- Índice de series y últimos valores. Cada partición lo hereda.
CREATE INDEX ix_vital_readings_series
    ON vital_readings (patient_id, type, measured_at DESC);

-- ─── Mantenimiento automático de particiones ────────────────────
CREATE OR REPLACE FUNCTION ensure_vital_readings_partitions(
    months_ahead int DEFAULT 3,
    months_back  int DEFAULT 0
)
RETURNS void AS $$
DECLARE
    m         int;
    base      date := date_trunc('month', now())::date;
    d_from    date;
    d_to      date;
    part_name text;
BEGIN
    FOR m IN -months_back..months_ahead LOOP
        d_from    := base + (m       || ' month')::interval;
        d_to      := base + ((m + 1) || ' month')::interval;
        part_name := format('vital_readings_%s', to_char(d_from, 'YYYY_MM'));

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF vital_readings
            FOR VALUES FROM (%L) TO (%L)',
            part_name,
            d_from::text || ' 00:00:00+00',
            d_to::text   || ' 00:00:00+00'
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ensure_vital_readings_partitions(int, int) IS
    'Crea las particiones mensuales faltantes. En producción el worker la llama cada mes con months_ahead=3.';

SELECT ensure_vital_readings_partitions(12, 12);

-- Red de seguridad: debe permanecer VACÍA.
CREATE TABLE vital_readings_default PARTITION OF vital_readings DEFAULT;

COMMENT ON TABLE  vital_readings IS
    'Mediciones de signos vitales. Particionada por mes (RNF-07). Tabla append-only. PK (id, measured_at): excepción técnica de PostgreSQL para tablas particionadas, documentada en el constraint pk_vital_readings.';
COMMENT ON COLUMN vital_readings.type IS
    'Tipo de signo vital. FK a vital_types.code (catálogo centralizado). Reemplaza el CHECK de lista duplicada.';
COMMENT ON COLUMN vital_readings.value IS
    'Valor principal. En presión arterial: sistólica.';
COMMENT ON COLUMN vital_readings.value_secondary IS
    'Solo para blood_pressure: diastólica. NULL en todos los demás tipos.';
COMMENT ON COLUMN vital_readings.measured_at IS
    'Momento de la medición. Columna de particionamiento. Parte de la PK por requerimiento técnico de PostgreSQL, no por diseño relacional.';
COMMENT ON COLUMN vital_readings.source IS
    'wearable = automática del dispositivo. manual = registrada por la cuidadora (RF-18).';
COMMENT ON COLUMN vital_readings.meta IS
    'Datos adicionales del proveedor del wearable. jsonb INTENCIONAL: cada proveedor (Garmin, Whoop, HealthKit) envía campos distintos y opcionales. No se consulta ni se filtra: solo se conserva como trazabilidad. Excepción documentada a 1FN.';


-- ============================================================================
-- Fuente: 203_vital_thresholds.sql
-- ============================================================================
-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla 3 de 3: vital_thresholds
--
-- Corrección 2FN:
--   · CHECK de type eliminado → FK a vital_types.code (catálogo centralizado).
--     Antes el mismo listado estaba duplicado en vital_readings y aquí.

CREATE TABLE vital_thresholds (
    id         uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id uuid         NOT NULL,
    -- FK al catálogo: fuente única de verdad para tipos válidos
    type       varchar(16)  NOT NULL,
    min_value  numeric(8,2),
    max_value  numeric(8,2),
    updated_by uuid,
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_vital_thresholds_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
    CONSTRAINT fk_vital_thresholds_user
        FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL,
    -- FK al catálogo: reemplaza el CHECK de lista duplicada
    CONSTRAINT fk_vital_thresholds_type
        FOREIGN KEY (type) REFERENCES vital_types(code),
    CONSTRAINT uq_vital_thresholds_patient_type
        UNIQUE (patient_id, type),
    CONSTRAINT ck_vital_thresholds_range
        CHECK (min_value IS NULL OR max_value IS NULL OR min_value < max_value),
    CONSTRAINT ck_vital_thresholds_at_least_one
        CHECK (min_value IS NOT NULL OR max_value IS NOT NULL)
);

CREATE TRIGGER tg_vital_thresholds_updated_at
    BEFORE UPDATE ON vital_thresholds
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  vital_thresholds IS
    'Rango normal de cada signo vital por paciente. Define cuándo una lectura dispara una alerta vital_out_of_range.';
COMMENT ON COLUMN vital_thresholds.type IS
    'Tipo de signo vital. FK a vital_types.code: reemplaza el CHECK de lista duplicada que existía en vital_readings y aquí.';
COMMENT ON COLUMN vital_thresholds.min_value IS
    'Límite inferior. NULL si el vital solo tiene techo (ej. temperatura).';
COMMENT ON COLUMN vital_thresholds.max_value IS
    'Límite superior. NULL si el vital solo tiene piso (ej. saturación O₂).';
COMMENT ON COLUMN vital_thresholds.updated_by IS
    'Quién configuró el umbral por última vez (RF-21). ON DELETE SET NULL: el umbral sigue vigente si el usuario se borra.';


-- ============================================================================
-- Fuente: 204_wellbeing_snapshots.sql
-- ============================================================================
-- AgeCare — Bloque 2: Vitals y wearable
-- Tabla: wellbeing_snapshots
--
-- Análisis de realidad:
--   El indicador diario de bienestar (semáforo: ok | warning | attention) se
--   calcula a partir de vitals, adherencia y eventos del día. Si solo se calcula
--   "al vuelo" al consultarlo, el expediente NO puede reconstruir cómo estuvo el
--   paciente en el pasado: la pregunta "¿cómo estuvo mamá la semana pasada?" queda
--   sin respuesta histórica.
--
--   Esta tabla persiste una fotografía diaria del semáforo por paciente. Un job
--   la calcula al cierre de cada día (y puede recalcular el día en curso). Da
--   soporte real al "expediente histórico" que promete el producto y a la
--   analítica de tendencias de bienestar.

CREATE TABLE wellbeing_snapshots (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    uuid        NOT NULL,
    snapshot_date date        NOT NULL,
    status        varchar(12) NOT NULL,
    -- Motivos legibles que explican el estado (p. ej. "SpO2 bajo el mínimo",
    -- "1 dosis omitida"). jsonb INTENCIONAL: lista de razones heterogéneas que
    -- solo se muestran, no se consultan ni se cruzan.
    reasons       jsonb       NOT NULL DEFAULT '[]'::jsonb,
    -- Conteos que respaldan el cálculo, para auditar cómo se llegó al estado.
    vitals_out_of_range smallint NOT NULL DEFAULT 0,
    doses_missed        smallint NOT NULL DEFAULT 0,
    active_alerts       smallint NOT NULL DEFAULT 0,
    computed_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_wellbeing_snapshots_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
    -- Una fotografía por paciente y día: recalcular el mismo día actualiza la fila.
    CONSTRAINT uq_wellbeing_snapshots_day
        UNIQUE (patient_id, snapshot_date),
    CONSTRAINT ck_wellbeing_snapshots_status
        CHECK (status IN ('ok','warning','attention')),
    CONSTRAINT ck_wellbeing_snapshots_reasons_array
        CHECK (jsonb_typeof(reasons) = 'array')
);

-- Serie histórica del semáforo de un paciente (tendencia de bienestar).
CREATE INDEX ix_wellbeing_snapshots_patient
    ON wellbeing_snapshots (patient_id, snapshot_date DESC);

COMMENT ON TABLE  wellbeing_snapshots IS
    'Fotografía diaria del semáforo de bienestar por paciente (ok | warning | attention). Historiza un indicador que de otro modo se perdería al calcularse al vuelo, dando soporte al expediente histórico y a la analítica de tendencias.';
COMMENT ON COLUMN wellbeing_snapshots.reasons IS
    'Motivos legibles del estado del día. jsonb INTENCIONAL: lista de razones que solo se muestran.';
COMMENT ON COLUMN wellbeing_snapshots.vitals_out_of_range IS
    'Conteo de vitales fuera de rango ese día; respalda y audita el cálculo del estado.';


-- ============================================================================
-- Fuente: 301_medications.sql
-- ============================================================================
-- AgeCare — Bloque 3: Medicación
-- Tabla 1 de 2: medications
--
-- Correcciones 2FN aplicadas:
--   · times jsonb eliminado → tabla medication_times (1FN: no grupos repetidos)
--   · days_of_week jsonb eliminado → tabla medication_days (1FN: no grupos repetidos)

CREATE TABLE medications (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid        NOT NULL,
    name            varchar(120) NOT NULL,
    -- Análisis de realidad: la dosis es cantidad + unidad, no un texto libre.
    -- Separarlas permite validar, comparar y (a futuro) calcular equivalencias.
    -- dose_text queda como presentación generada para la interfaz.
    dose_amount     numeric(8,2) NOT NULL,
    dose_unit       varchar(20)  NOT NULL,
    dose_text       varchar(60)  GENERATED ALWAYS AS
                        (trim(to_char(dose_amount, 'FM999999990.##')) || ' ' || dose_unit) STORED,
    instructions    text,
    start_date      date         NOT NULL,
    end_date        date,
    grace_window_min smallint    NOT NULL DEFAULT 60,
    prescribed_by   uuid,
    discontinued_at timestamptz,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT fk_medications_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
    CONSTRAINT fk_medications_prescriber
        FOREIGN KEY (prescribed_by) REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT ck_medications_dates
        CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT ck_medications_grace
        CHECK (grace_window_min BETWEEN 5 AND 720),
    CONSTRAINT ck_medications_name_min
        CHECK (char_length(name) >= 2),
    CONSTRAINT ck_medications_dose_amount
        CHECK (dose_amount > 0),
    CONSTRAINT ck_medications_dose_unit
        CHECK (dose_unit IN ('mg','g','ml','mcg','UI','gotas','comprimido','cápsula','puff','parche'))
);

-- Plan vigente de un paciente (endpoint 6.2) y el job generador de dosis.
CREATE INDEX ix_medications_patient_active
    ON medications (patient_id) WHERE discontinued_at IS NULL;

CREATE TRIGGER tg_medications_updated_at
    BEFORE UPDATE ON medications
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  medications IS
    'Plan de medicamentos: QUÉ se administra y CON QUÉ FRECUENCIA. Las tomas concretas se materializan en scheduled_doses. Los horarios y días viven en medication_times y medication_days (1FN).';
COMMENT ON COLUMN medications.dose_amount IS
    'Cantidad numérica de la dosis (p. ej. 50). Separada de la unidad para poder validar y comparar; antes era un varchar "50 mg" no computable.';
COMMENT ON COLUMN medications.dose_unit IS
    'Unidad de la dosis: mg | g | ml | mcg | UI | gotas | comprimido | cápsula | puff | parche.';
COMMENT ON COLUMN medications.dose_text IS
    'Presentación generada (dose_amount + dose_unit) para la interfaz. Solo lectura.';
COMMENT ON COLUMN medications.grace_window_min IS
    'Minutos de tolerancia tras la hora programada antes de marcar la dosis como omitida y alertar (Anexo B).';
COMMENT ON COLUMN medications.prescribed_by IS
    'Quién definió el plan: médico o cuidadora (RF-24). ON DELETE SET NULL: el plan sobrevive a la cuenta.';
COMMENT ON COLUMN medications.discontinued_at IS
    'Descontinuación. Cancela las tomas futuras y conserva el historial (RF-27). NULL = vigente.';


-- ─────────────────────────────────────────────────────────────────
-- medication_times
-- Normalización 1FN: reemplaza la columna times jsonb de medications.
-- Cada horario de toma es una entidad propia (una fila, un valor atómico).
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE medication_times (
    id            uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    medication_id uuid    NOT NULL,
    time_of_day   time    NOT NULL,

    CONSTRAINT fk_medication_times_medication
        FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE CASCADE,
    -- Un medicamento no puede tener el mismo horario dos veces
    CONSTRAINT uq_medication_times_slot
        UNIQUE (medication_id, time_of_day)
);

-- El job generador de dosis consulta todos los horarios de un medicamento.
CREATE INDEX ix_medication_times_medication
    ON medication_times (medication_id);

COMMENT ON TABLE  medication_times IS
    'Horarios de toma de cada medicamento. Normalización 1FN: reemplaza el arreglo JSON times de medications. Cada fila = un horario atómico (HH:MM).';
COMMENT ON COLUMN medication_times.time_of_day IS
    'Hora de toma en la zona horaria del paciente (patients.timezone). Tipo TIME sin zona: la conversión la aplica el job al generar scheduled_doses.';


-- ─────────────────────────────────────────────────────────────────
-- medication_days
-- Normalización 1FN: reemplaza la columna days_of_week jsonb de medications.
-- Cada día habilitado es una fila propia.
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE medication_days (
    medication_id uuid     NOT NULL,
    day_of_week   smallint NOT NULL,

    PRIMARY KEY (medication_id, day_of_week),

    CONSTRAINT fk_medication_days_medication
        FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE CASCADE,
    -- 1 = lunes … 7 = domingo (ISO 8601)
    CONSTRAINT ck_medication_days_range
        CHECK (day_of_week BETWEEN 1 AND 7)
);

COMMENT ON TABLE  medication_days IS
    'Días de la semana habilitados para cada medicamento. Normalización 1FN: reemplaza el arreglo JSON days_of_week de medications. PK compuesta (medication_id, day_of_week): cada fila es atómica.';
COMMENT ON COLUMN medication_days.day_of_week IS
    '1 = lunes, 2 = martes, …, 7 = domingo. ISO 8601. Sin fila = ese día no se administra.';


-- ============================================================================
-- Fuente: 302_scheduled_doses.sql
-- ============================================================================
-- AgeCare — Bloque 3: Medicación
-- Tabla 2 de 2: scheduled_doses
--
-- Correcciones 2FN aplicadas:
--   · patient_id eliminado: dependencia parcial (patient_id dependía de medication_id,
--     no de la PK id). Viola 2FN. Las consultas por paciente hacen JOIN con medications.

CREATE TABLE scheduled_doses (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    medication_id uuid        NOT NULL,
    scheduled_at  timestamptz NOT NULL,
    status        varchar(10) NOT NULL DEFAULT 'pending',
    -- Análisis de realidad: tres momentos DISTINTOS que no deben confundirse.
    --   scheduled_at   = cuándo DEBÍA administrarse la dosis (planificado).
    --   administered_at= cuándo REALMENTE se administró al paciente (hecho clínico).
    --   logged_at      = cuándo la cuidadora lo REGISTRÓ en la app (acto administrativo).
    -- Permite distinguir "se dio a tiempo pero se registró tarde" de "se dio tarde".
    administered_at timestamptz,
    logged_by     uuid,
    logged_at     timestamptz,
    reason        varchar(200),
    postponed_until timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_scheduled_doses_medication
        FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE CASCADE,
    CONSTRAINT fk_scheduled_doses_user
        FOREIGN KEY (logged_by) REFERENCES users(id) ON DELETE SET NULL,

    -- Idempotencia del job generador: un slot por medicamento y hora
    CONSTRAINT uq_scheduled_doses_slot
        UNIQUE (medication_id, scheduled_at),

    CONSTRAINT ck_scheduled_doses_status
        CHECK (status IN ('pending','taken','skipped','postponed','missed')),
    -- RF-29: omitir exige motivo
    CONSTRAINT ck_scheduled_doses_skip_reason
        CHECK (status <> 'skipped' OR reason IS NOT NULL),
    -- Quién y cuándo van siempre juntos
    CONSTRAINT ck_scheduled_doses_logged_pair
        CHECK ((logged_at IS NULL) = (logged_by IS NULL)),
    -- Confirmar o descartar requiere registro de quién y cuándo
    CONSTRAINT ck_scheduled_doses_logged_status
        CHECK (status NOT IN ('taken','skipped') OR logged_at IS NOT NULL),
    -- Una dosis administrada debe tener la hora real de administración.
    CONSTRAINT ck_scheduled_doses_administered
        CHECK (status <> 'taken' OR administered_at IS NOT NULL),
    -- No se puede administrar una dosis antes de que estuviera programada.
    CONSTRAINT ck_scheduled_doses_admin_order
        CHECK (administered_at IS NULL OR administered_at >= scheduled_at),
    -- Posponer exige nueva hora
    CONSTRAINT ck_scheduled_doses_postponed
        CHECK (status <> 'postponed' OR postponed_until IS NOT NULL),
    -- Máximo 4 horas de postergación (endpoint 6.6)
    CONSTRAINT ck_scheduled_doses_postpone_limit
        CHECK (postponed_until IS NULL OR
            postponed_until <= scheduled_at + interval '4 hours')
);

-- Agenda del día: JOIN con medications para obtener patient_id.
-- La consulta más frecuente: dosis pendientes de un paciente en una fecha.
--   SELECT sd.*
--   FROM scheduled_doses sd
--   JOIN medications m ON m.id = sd.medication_id
--   WHERE m.patient_id = $1
--     AND sd.scheduled_at::date = $2
--   ORDER BY sd.scheduled_at;
CREATE INDEX ix_scheduled_doses_medication_time
    ON scheduled_doses (medication_id, scheduled_at DESC);

-- El vigilante de ventanas vencidas (Anexo B).
CREATE INDEX ix_scheduled_doses_pending
    ON scheduled_doses (scheduled_at) WHERE status = 'pending';

CREATE TRIGGER tg_scheduled_doses_updated_at
    BEFORE UPDATE ON scheduled_doses
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  scheduled_doses IS
    'Tomas concretas generadas a partir del plan (medications + medication_times + medication_days). Existen ANTES de ocurrir, lo que permite registrar ausencias y calcular adherencia: sin estas filas no habría denominador.';
COMMENT ON COLUMN scheduled_doses.status IS
    'pending | taken | skipped | postponed | missed.';
COMMENT ON COLUMN scheduled_doses.scheduled_at IS
    'Momento en que la dosis DEBÍA administrarse (planificado por el job según el plan).';
COMMENT ON COLUMN scheduled_doses.administered_at IS
    'Momento REAL de administración al paciente (hecho clínico). Distinto de logged_at: una dosis puede darse a las 08:00 y registrarse a las 23:00. Base para medir puntualidad real, no solo adherencia administrativa.';
COMMENT ON COLUMN scheduled_doses.logged_at IS
    'Momento en que la cuidadora REGISTRÓ la dosis en la app (acto administrativo). Junto con logged_by da trazabilidad y responsabilidad del registro.';
COMMENT ON COLUMN scheduled_doses.logged_by IS
    'Usuario que registró la dosis. Es la rendición de cuentas del acto: el sistema no puede validar la administración física, pero sí dejar evidencia inmutable de quién la declaró y cuándo.';
COMMENT ON COLUMN scheduled_doses.reason IS
    'Motivo de la omisión. Obligatorio cuando el estado es skipped (RF-29).';
COMMENT ON COLUMN scheduled_doses.postponed_until IS
    'Nueva hora tras posponer. Máximo 4 horas después de lo programado (endpoint 6.6).';


-- ============================================================================
-- Fuente: 401_alerts.sql
-- ============================================================================
-- AgeCare — Bloque 4: Alertas y emergencias
-- Tabla 1 de 5: alerts

CREATE TABLE alerts (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
type varchar(20) NOT NULL,
severity varchar(10) NOT NULL,
title varchar(120) NOT NULL,
detail text,
payload jsonb,
dedup_key varchar(60),
status varchar(12) NOT NULL DEFAULT 'active',
acknowledged_by uuid,
acknowledged_at timestamptz,
resolved_by uuid,
resolved_at timestamptz,
resolution_note varchar(500),
escalated_at timestamptz,
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_alerts_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_alerts_acknowledged_by
    FOREIGN KEY (acknowledged_by) REFERENCES users(id) ON DELETE SET NULL,
CONSTRAINT fk_alerts_resolved_by
    FOREIGN KEY (resolved_by) REFERENCES users(id) ON DELETE SET NULL,

CONSTRAINT ck_alerts_type
    CHECK (type IN ('fall','vital_out_of_range','missed_dose','sos','wearable_offline')),
CONSTRAINT ck_alerts_severity
    CHECK (severity IN ('info','warning','critical')),
CONSTRAINT ck_alerts_status
    CHECK (status IN ('active','acknowledged','resolved')),

-- Atender registra quién y cuándo, siempre juntos
CONSTRAINT ck_alerts_ack_pair
    CHECK ((acknowledged_at IS NULL) = (acknowledged_by IS NULL)),
CONSTRAINT ck_alerts_resolved_pair
    CHECK ((resolved_at IS NULL) = (resolved_by IS NULL)),
-- El estado tiene que ser coherente con las marcas de tiempo
CONSTRAINT ck_alerts_status_ack
    CHECK (status = 'active' OR acknowledged_at IS NOT NULL),
CONSTRAINT ck_alerts_status_resolved
    CHECK (status <> 'resolved' OR resolved_at IS NOT NULL),
-- No se puede resolver antes de atender
CONSTRAINT ck_alerts_order
    CHECK (resolved_at IS NULL OR acknowledged_at IS NULL
        OR resolved_at >= acknowledged_at)
);

-- Centro de alertas: activas primero, más recientes arriba.
CREATE INDEX ix_alerts_patient_status
    ON alerts (patient_id, status, created_at DESC);

-- Deduplicación: buscar la misma condición en los últimos 30 minutos.
CREATE INDEX ix_alerts_dedup
    ON alerts (patient_id, dedup_key, created_at DESC)
    WHERE dedup_key IS NOT NULL;

-- Vigilante de escalamiento: críticas sin atender.
CREATE INDEX ix_alerts_pending_critical
    ON alerts (created_at) WHERE status = 'active' AND severity = 'critical';

CREATE TRIGGER tg_alerts_updated_at
    BEFORE UPDATE ON alerts
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  alerts IS
    'Alertas generadas por el sistema. Pilar central del producto: caída, vital fuera de rango, dosis no administrada, SOS y wearable sin datos.';
COMMENT ON COLUMN alerts.updated_at IS
    'Última modificación. Columna renombrada de update_at (typo corregido): el trigger tg_alerts_updated_at la mantiene actualizada en cada UPDATE.';
COMMENT ON COLUMN alerts.acknowledged_at IS
    'Momento en que alguien atendió la alerta. NO está en el Anexo A: se agrega porque sin ella es imposible medir el tiempo de respuesta que exigen el ticket AGE-508 y el objetivo específico de Fase 1.';
COMMENT ON COLUMN alerts.dedup_key IS
    'Identifica la condición que originó la alerta (ej. spo2_low). Permite no repetir alertas por la misma causa dentro de 30 minutos (RF-46, AGE-501). La ventana de tiempo la evalúa el motor; la base aporta el índice.';
COMMENT ON COLUMN alerts.payload IS
    'Datos que originaron la alerta (lectura fuera de rango, dosis omitida, etc.). Se mantiene como jsonb de forma INTENCIONAL: la estructura varía según el tipo de alerta (patrón de atributos variables). Normalizarlo exigiría una tabla de detalle por cada tipo, lo que no aporta integridad porque estos datos no se consultan ni se cruzan: solo se muestran al abrir la alerta. Excepción documentada a 1FN.';
COMMENT ON COLUMN alerts.escalated_at IS
    'Momento en que se escaló a los siguientes contactos por falta de atención (RF-52). NULL = no escalada.';


-- ============================================================================
-- Fuente: 402_alert_deliveries.sql
-- ============================================================================
-- AgeCare — Bloque 4: Alertas y emergencias
-- Tabla 2 de 5: alert_deliveries

CREATE TABLE alert_deliveries (
id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
alert_id uuid NOT NULL,
user_id uuid NOT NULL,
push_device_id uuid,
channel  varchar(10) NOT NULL DEFAULT 'push',
status  varchar(10) NOT NULL DEFAULT 'queued',
sent_at  timestamptz,
delivered_at timestamptz,
opened_at timestamptz,
error_detail varchar(300),
created_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_alert_deliveries_alert
    FOREIGN KEY (alert_id) REFERENCES alerts(id) ON DELETE CASCADE,
CONSTRAINT fk_alert_deliveries_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT fk_alert_deliveries_device
    FOREIGN KEY (push_device_id) REFERENCES push_devices(id) ON DELETE SET NULL,

CONSTRAINT ck_alert_deliveries_channel
    CHECK (channel IN ('push','email','sms','in_app')),
CONSTRAINT ck_alert_deliveries_status
    CHECK (status IN ('queued','sent','delivered','opened','failed')),
CONSTRAINT ck_alert_deliveries_failed
    CHECK (status <> 'failed' OR error_detail IS NOT NULL),
-- La secuencia temporal no puede ir al revés
CONSTRAINT ck_alert_deliveries_order
    CHECK ((delivered_at IS NULL OR sent_at IS NULL OR delivered_at >= sent_at)
    AND (opened_at    IS NULL OR delivered_at IS NULL OR opened_at >= delivered_at))
);

-- Todas las entregas de una alerta (para el detalle y el diagnóstico).
CREATE INDEX ix_alert_deliveries_alert
    ON alert_deliveries (alert_id);

-- Reintentos y diagnóstico de fallas.
CREATE INDEX ix_alert_deliveries_failed
    ON alert_deliveries (created_at) WHERE status = 'failed';

COMMENT ON TABLE  alert_deliveries IS
    'Una fila por cada intento de notificar a una persona sobre una alerta. No está en el Anexo A: se agrega porque sin ella los RNF-04 y RNF-05, que exigen latencias medibles, no se pueden comprobar.';
COMMENT ON COLUMN alert_deliveries.sent_at IS
    'Momento en que el backend entregó la notificación al proveedor de push.';
COMMENT ON COLUMN alert_deliveries.delivered_at IS
    'Momento en que el proveedor confirmó la entrega al aparato. La diferencia con sent_at es la latencia que mide el RNF-05.';
COMMENT ON COLUMN alert_deliveries.opened_at IS
    'Momento en que el usuario abrió la notificación. Distinto de delivered_at: llegar no es lo mismo que enterarse.';
COMMENT ON COLUMN alert_deliveries.channel IS
    'push es el canal principal. Los demás cubren el RF-82: vía alternativa cuando el push no se puede entregar.';


-- ============================================================================
-- Fuente: 403_notification_settings.sql
-- ============================================================================
-- Tabla 3 de 5: notification_settings


CREATE TABLE notification_settings (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
user_id uuid  NOT NULL,
alert_type varchar(20) NOT NULL,
push_enabled boolean NOT NULL DEFAULT true,
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_notification_settings_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
CONSTRAINT uq_notification_settings_pair
    UNIQUE (user_id, alert_type),
CONSTRAINT ck_notification_settings_type
    CHECK (alert_type IN ('fall','vital_out_of_range','missed_dose','sos','wearable_offline')),
CONSTRAINT ck_notification_settings_critical_locked
    CHECK (push_enabled OR alert_type NOT IN ('fall','sos'))
);

CREATE TRIGGER tg_notification_settings_updated_at
    BEFORE UPDATE ON notification_settings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  notification_settings IS
    'Preferencias de notificación por usuario y tipo de alerta (endpoints 9.4 y 9.5).';
COMMENT ON CONSTRAINT ck_notification_settings_critical_locked ON notification_settings IS
    'Las alertas de caída y SOS no se pueden desactivar (RF-50). La restricción vive en la base, no solo en la interfaz.';


-- ============================================================================
-- Fuente: 404_emergency_contacts.sql
-- ============================================================================
-- Tabla 4 de 5: emergency_contacts
CREATE TABLE emergency_contacts (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
-- 1FN y coherencia con users/patients: nombre y apellido son atributos distintos.
-- full_name queda como columna GENERATED para presentación y compatibilidad.
first_name varchar(60) NOT NULL,
last_name  varchar(60) NOT NULL,
full_name  varchar(121) GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
relationship  varchar(40),
phone varchar(16)  NOT NULL,
escalation_order smallint NOT NULL DEFAULT 1,
notes varchar(200),
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now(),
deleted_at timestamptz,

CONSTRAINT fk_emergency_contacts_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT ck_emergency_contacts_first_name
    CHECK (char_length(first_name) >= 1),
CONSTRAINT ck_emergency_contacts_last_name
    CHECK (char_length(last_name) >= 1),
CONSTRAINT ck_emergency_contacts_order
    CHECK (escalation_order BETWEEN 1 AND 10),
CONSTRAINT ck_emergency_contacts_phone
    CHECK (phone ~ '^\+[0-9]{8,15}$')
);

-- Dos contactos no pueden tener la misma prioridad para un paciente.
CREATE UNIQUE INDEX ux_emergency_contacts_order
    ON emergency_contacts (patient_id, escalation_order)
    WHERE deleted_at IS NULL;

CREATE TRIGGER tg_emergency_contacts_updated_at
    BEFORE UPDATE ON emergency_contacts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  emergency_contacts IS
    'Contactos de emergencia del paciente, en orden de escalamiento. No está en el Anexo A: se agrega porque el endpoint 9.6 debe devolver estos teléfonos y el RF-52 exige escalar a los siguientes cuando nadie atiende.';
COMMENT ON COLUMN emergency_contacts.escalation_order IS
    'Prioridad de aviso: 1 primero. Sin este orden, "los siguientes contactos" del RF-52 no se puede implementar.';


-- ============================================================================
-- Fuente: 405_sos_events.sql
-- ============================================================================
-- Tabla 5 de 5: sos_events
CREATE TABLE sos_events (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
patient_id uuid NOT NULL,
triggered_by uuid,
alert_id uuid NOT NULL,
note varchar(300),
latitude numeric(9,6),
longitude numeric(9,6),
created_at timestamptz NOT NULL DEFAULT now(),

CONSTRAINT fk_sos_events_patient
    FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
CONSTRAINT fk_sos_events_user
    FOREIGN KEY (triggered_by) REFERENCES users(id) ON DELETE SET NULL,
CONSTRAINT fk_sos_events_alert
    FOREIGN KEY (alert_id) REFERENCES alerts(id) ON DELETE CASCADE,
CONSTRAINT uq_sos_events_alert
    UNIQUE (alert_id),
CONSTRAINT ck_sos_events_coords
    CHECK ((latitude IS NULL) = (longitude IS NULL)),
CONSTRAINT ck_sos_events_lat
    CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
CONSTRAINT ck_sos_events_lng
    CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180)
);

CREATE INDEX ix_sos_events_patient
    ON sos_events (patient_id, created_at DESC);

COMMENT ON TABLE  sos_events IS
    'Activaciones del botón de emergencia. Cada una genera exactamente una alerta crítica (UNIQUE sobre alert_id).';
COMMENT ON COLUMN sos_events.latitude IS
    'Ubicación al momento del SOS. No está en el Anexo A, pero la app la captura: el pubspec.yaml incluye geolocator con el comentario "ubicación para SOS".';
COMMENT ON COLUMN sos_events.triggered_by IS
    'Quién lo activó: cuidadora o el propio adulto mayor (RF-51). ON DELETE SET NULL: el evento queda en el expediente.';


-- ============================================================================
-- Fuente: 501_subscriptions.sql
-- ============================================================================
-- AgeCare — Bloque 5: Negocio (freemium)
-- Tabla: subscriptions
--
-- Análisis de negocio (RF-73, objetivo de conversión del modelo freemium):
--   El documento de negocio promete un modelo freemium con conversión a Premium.
--   Sin una tabla que modele el estado de suscripción, el objetivo "10% de
--   conversión" no es medible ni el requisito RF-73 ("bloquear funciones de pago
--   sin suscripción vigente") es implementable: no habría contra qué validar.
--
--   La suscripción pertenece a un USUARIO (la cuidadora en v1, extensible a
--   familiar). Una fila representa un período de suscripción; el historial se
--   conserva (no se borra al expirar) para analítica de retención y churn.

CREATE TABLE subscriptions (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid        NOT NULL,
    plan          varchar(20) NOT NULL,
    status        varchar(20) NOT NULL DEFAULT 'active',
    started_at    timestamptz NOT NULL DEFAULT now(),
    -- Fin del período vigente. NULL mientras esté activa sin fecha de corte.
    current_period_end timestamptz,
    cancelled_at  timestamptz,
    -- Referencia opaca a la pasarela de pago (no se guardan datos de tarjeta).
    provider_ref  varchar(120),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_subscriptions_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT ck_subscriptions_plan
        CHECK (plan IN ('free','premium')),
    CONSTRAINT ck_subscriptions_status
        CHECK (status IN ('active','past_due','cancelled','expired')),
    -- Cancelar exige marca de tiempo de cancelación.
    CONSTRAINT ck_subscriptions_cancelled_pair
        CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL)
);

-- Suscripción vigente de un usuario (la consulta de RF-73 al bloquear premium).
-- Un solo registro ACTIVO por usuario; el historial de períodos cerrados se conserva.
CREATE UNIQUE INDEX ux_subscriptions_active_user
    ON subscriptions (user_id) WHERE status = 'active';

CREATE INDEX ix_subscriptions_user
    ON subscriptions (user_id, created_at DESC);

CREATE TRIGGER tg_subscriptions_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  subscriptions IS
    'Suscripciones del modelo freemium (RF-73). Da soporte a la validación de acceso a funciones de pago y a la métrica de conversión del plan de negocio. Conserva el historial de períodos para analítica de retención.';
COMMENT ON COLUMN subscriptions.plan IS
    'free | premium. El adulto mayor nunca paga; en v1 la suscripción aplica a la cuidadora.';
COMMENT ON COLUMN subscriptions.status IS
    'active | past_due | cancelled | expired. Solo una activa por usuario (índice parcial).';
COMMENT ON COLUMN subscriptions.provider_ref IS
    'Referencia opaca a la pasarela de pago. NO se almacenan datos de tarjeta (cumplimiento PCI).';


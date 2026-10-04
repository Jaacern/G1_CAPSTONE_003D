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

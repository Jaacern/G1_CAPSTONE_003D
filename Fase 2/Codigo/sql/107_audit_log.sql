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

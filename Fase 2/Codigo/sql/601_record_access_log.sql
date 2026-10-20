-- ============================================================================
-- BLOQUE 6 · Auditoria y administracion
-- 601_record_access_log.sql — Registro de accesos al expediente
-- Requisitos: RNF-14 (trazabilidad: quien consulto que expediente y cuando)
-- ----------------------------------------------------------------------------
-- Por que esta tabla y no audit_log:
--   audit_log guarda CAMBIOS, con old_value y new_value en jsonb. Es ancha y
--   crece al ritmo de las escrituras. Las CONSULTAS son otro orden de
--   magnitud: cada vez que un familiar abre el expediente se genera una fila.
--   Meterlas en audit_log inflaria la tabla de cambios con filas que tienen
--   los dos jsonb vacios, y arruinaria las consultas de auditoria clinica.
--   Son dos hechos distintos con dos volumenes distintos, asi que van en dos
--   tablas distintas.
--
-- role se guarda aqui aunque ya exista en patient_members. Es una
-- desnormalizacion deliberada: el rol con que alguien accedio en marzo es un
-- hecho historico. Si manana se le cambia el rol o se lo saca del circulo, la
-- auditoria tiene que seguir diciendo con que permiso entro ese dia.
--
-- Particionado mensual por el mismo motivo que vital_readings (RNF-07): es la
-- segunda tabla que mas crece y los profesores piden conservar datos para
-- analisis a dos o tres anos.
-- ============================================================================

CREATE TABLE record_access_log (
    id          uuid        NOT NULL DEFAULT gen_random_uuid(),
    patient_id  uuid        NOT NULL,
    user_id     uuid        NOT NULL,
    role        varchar(10) NOT NULL,
    section     varchar(24) NOT NULL,
    entity_id   uuid,
    ip_address  inet,
    user_agent  varchar(300),
    accessed_at timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (id, accessed_at),

    CONSTRAINT fk_record_access_log_patient
        FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_record_access_log_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT ck_record_access_log_role CHECK (
        role IN ('family','caregiver','doctor','elder')
    ),
    CONSTRAINT ck_record_access_log_section CHECK (
        section IN ('profile','vitals','medications','doses','logbook',
                    'documents','alerts','chat','reports','members')
    )
) PARTITION BY RANGE (accessed_at);

-- Particiones mensuales. Se crean por adelantado igual que en vital_readings;
-- la particion DEFAULT recibe cualquier fecha fuera de rango para que una
-- insercion nunca falle por falta de particion.
DO $$
DECLARE
    mes date := date '2026-10-01';
    fin date := date '2028-01-01';
BEGIN
    WHILE mes < fin LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS record_access_log_%s '
            'PARTITION OF record_access_log FOR VALUES FROM (%L) TO (%L)',
            to_char(mes, 'YYYYMM'), mes, mes + interval '1 month'
        );
        mes := mes + interval '1 month';
    END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS record_access_log_default
    PARTITION OF record_access_log DEFAULT;

-- RNF-14: "quien consulto este expediente", la consulta que pide el requisito.
CREATE INDEX ix_record_access_log_patient
    ON record_access_log (patient_id, accessed_at DESC);

-- La vuelta contraria: a que expedientes accedio un usuario.
CREATE INDEX ix_record_access_log_user
    ON record_access_log (user_id, accessed_at DESC);

COMMENT ON TABLE  record_access_log IS 'Registro de cada consulta al expediente de un paciente. Append-only y particionado por mes. Responde quien vio que y cuando. RNF-14.';
COMMENT ON COLUMN record_access_log.id IS 'Identificador del acceso.';
COMMENT ON COLUMN record_access_log.patient_id IS 'Expediente consultado.';
COMMENT ON COLUMN record_access_log.user_id IS 'Usuario que consulto.';
COMMENT ON COLUMN record_access_log.role IS 'Rol con que accedio, congelado al momento del acceso. No se recalcula si el rol cambia despues.';
COMMENT ON COLUMN record_access_log.section IS 'Seccion del expediente consultada.';
COMMENT ON COLUMN record_access_log.entity_id IS 'Registro puntual consultado dentro de la seccion, cuando aplica.';
COMMENT ON COLUMN record_access_log.ip_address IS 'Direccion IP de origen.';
COMMENT ON COLUMN record_access_log.user_agent IS 'Identificacion del cliente que hizo la consulta.';
COMMENT ON COLUMN record_access_log.accessed_at IS 'Momento del acceso. Es la clave de particionado.';

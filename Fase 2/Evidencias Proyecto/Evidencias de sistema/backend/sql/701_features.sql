-- ============================================================================
-- BLOQUE 7 · Planes y suscripciones
-- 701_features.sql — Catalogo de funcionalidades
-- Requisitos: RF-73 (distinguir funciones gratuitas de pago),
--             RF-83 a RF-85 (constructor de planes de Alloxentric)
-- ----------------------------------------------------------------------------
-- Esta es la pieza que hoy no existe y por la que subscriptions.plan es un
-- texto suelto. Sin catalogo de funcionalidades, "bloquear premium sin
-- suscripcion" (RF-73) solo se puede escribir a mano en el codigo, con una
-- lista de ifs. Con catalogo, la pregunta se responde con una consulta:
-- esta funcion esta incluida en el plan de este usuario, si o no.
--
-- La PK es el code y no un uuid, por la misma razon que en vital_types: el
-- codigo es lo que la aplicacion escribe en el codigo fuente
-- ('assistant_ia'), y es estable. Un uuid obligaria a un join para algo que
-- ya es legible, y a que el codigo fuente cargue identificadores opacos.
-- ============================================================================

CREATE TABLE features (
    code        varchar(40)  PRIMARY KEY,
    label       varchar(80)  NOT NULL,
    description varchar(300) NOT NULL,
    module      varchar(20)  NOT NULL,
    is_core     boolean      NOT NULL DEFAULT false,
    created_at  timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT ck_features_code CHECK (code ~ '^[a-z][a-z0-9_]{2,39}$'),
    CONSTRAINT ck_features_module CHECK (
        module IN ('health','medication','alerts','logbook','documents',
                   'chat','assistant','elder','marketplace','reports')
    ),
    CONSTRAINT ck_features_label CHECK (btrim(label) <> '')
);

-- Armado de la pantalla de comparacion de planes, agrupada por modulo.
CREATE INDEX ix_features_module ON features (module, code);

COMMENT ON TABLE  features IS 'Catalogo de funcionalidades que un plan puede incluir o no. Fuente unica de verdad para RF-73 y para el constructor de planes. RF-83 a RF-85.';
COMMENT ON COLUMN features.code IS 'Codigo estable de la funcionalidad. Es lo que consulta la aplicacion.';
COMMENT ON COLUMN features.label IS 'Nombre visible de la funcionalidad.';
COMMENT ON COLUMN features.description IS 'Que hace la funcionalidad, en lenguaje de usuario.';
COMMENT ON COLUMN features.module IS 'Modulo del sistema al que pertenece.';
COMMENT ON COLUMN features.is_core IS 'Verdadero si la funcionalidad es del nucleo y ningun plan puede quitarla.';
COMMENT ON COLUMN features.created_at IS 'Fecha de creacion del registro.';

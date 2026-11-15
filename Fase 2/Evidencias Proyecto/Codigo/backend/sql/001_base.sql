-- ============================================================================
-- POLITICA DE CONSERVACION DE DATOS
-- ----------------------------------------------------------------------------
-- El modelo NO admite borrado fisico. Las 36 claves foraneas usan
-- ON DELETE RESTRICT, de modo que el motor impide eliminar una fila que tenga
-- registros asociados. No es una convencion del codigo: es el propio Postgres
-- el que lo rechaza.
--
-- Motivo: los datos clinicos e historicos son la base del analisis posterior.
-- Una fila borrada hoy es una pregunta que no se podra responder en dos anos.
--
-- Como se da de baja un registro:
--   · Marcas de desactivacion: deleted_at, removed_at, unlinked_at,
--     discontinued_at, revoked_at, cancelled_at. La fila queda, deja de usarse.
--   · Eliminacion de cuenta (exigencia de las tiendas y de la ley de datos
--     personales): se anonimizan los campos identificatorios del usuario y se
--     conservan los hechos registrados. El analisis no necesita saber QUIEN
--     era, necesita saber QUE paso.
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


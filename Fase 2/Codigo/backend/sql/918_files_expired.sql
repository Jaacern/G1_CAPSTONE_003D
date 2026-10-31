-- AgeCare — Ajuste de coherencia
-- 918_files_expired.sql — Un cuarto estado para las subidas que nunca llegaron
--
-- EL PROBLEMA
--   files.status aceptaba tres valores: pending, stored y purged.
--
--   Una fila nace pending cuando alguien pide el enlace de subida y pasa a
--   stored cuando el binario llega. Pero el enlace vive 15 minutos (RNF-13) y
--   hay varias formas de que el binario no llegue nunca: la familia cierra la
--   aplicacion a medias, se corta el dato movil en la casa del paciente, el
--   telefono se queda sin bateria.
--
--   Esas filas se quedaban pending para siempre. El estado pasaba a ser
--   mentira: pending significa "lo estamos esperando", y a las 15 minutos ya
--   no se espera nada. Peor todavia, no habia forma de distinguir una subida
--   que empezo hace diez segundos de una abandonada en agosto.
--
--   No se puede resolver marcandolas purged, porque purged exige stored_at y
--   estas filas nunca tuvieron un archivo que depurar. El CHECK de fechas lo
--   impide, y hace bien: purged describe un archivo que existio y se elimino.
--
-- LA CORRECCION
--   Se agrega el estado expired, con las dos fechas en NULL, para la subida
--   que se pidio y no se completo.
--
--   Las filas NO se borran. Es la misma regla que en el resto del esquema: si
--   alguien pidio subir un documento al expediente de un paciente, queda
--   constancia de que lo pidio, aunque el archivo no haya llegado. Sirve para
--   explicar un hueco en el expediente y para notar que un usuario tiene mil
--   subidas fallidas, que normalmente significa que la aplicacion le esta
--   fallando en su conexion.

ALTER TABLE files DROP CONSTRAINT IF EXISTS ck_files_status;

ALTER TABLE files ADD CONSTRAINT ck_files_status CHECK (
    status IN ('pending', 'stored', 'expired', 'purged')
);

ALTER TABLE files DROP CONSTRAINT IF EXISTS ck_files_status_dates;

-- Coherencia de estado. Cada estado dice exactamente que fechas tiene, asi
-- que no hay forma de que una fila quede a medio camino entre dos.
ALTER TABLE files ADD CONSTRAINT ck_files_status_dates CHECK (
    (status = 'pending' AND stored_at IS NULL     AND purged_at IS NULL)
 OR (status = 'expired' AND stored_at IS NULL     AND purged_at IS NULL)
 OR (status = 'stored'  AND stored_at IS NOT NULL AND purged_at IS NULL)
 OR (status = 'purged'  AND stored_at IS NOT NULL AND purged_at IS NOT NULL)
);

-- El barrido busca por estado y por fecha de vencimiento juntas. Sin este
-- indice tendria que recorrer la tabla completa de archivos cada vez que
-- corre, y la tabla de archivos es de las que crecen sin parar.
CREATE INDEX IF NOT EXISTS ix_files_pending_vencidas
    ON files (upload_expires_at)
    WHERE status = 'pending';

COMMENT ON COLUMN files.status IS
    'Estado del archivo. pending: se entrego el enlace de subida y se espera el binario. stored: el binario esta guardado. expired: el enlace vencio sin que llegara el binario, la fila se conserva como constancia del intento. purged: el binario se elimino del almacenamiento.';

-- Revierte 969_claves_de_reenvio.sql
--
-- PIERDE DATOS: se olvidan las respuestas guardadas de los reenvios. El
-- efecto practico es acotado, porque son memoria de corto plazo: lo unico
-- que puede pasar es que un reintento que estaba en vuelo duplique su
-- accion. Si se revierte con la app en uso, conviene hacerlo cuando no haya
-- cola pendiente.

DROP INDEX IF EXISTS ix_idempotency_keys_created;
DROP TABLE IF EXISTS idempotency_keys;

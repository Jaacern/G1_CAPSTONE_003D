# Reverts de las migraciones (RNF-24)

Cada migracion que cambia el esquema tiene aqui un archivo con el mismo
nombre que deshace lo que hizo. Las semillas de datos de demostracion no
llevan revert y lo dicen con la marca `-- SEMILLA` en su cabecera: revertir
una semilla seria borrar datos de ejemplo, no deshacer un cambio de esquema.

Se usan con el aplicador, que ademas borra la fila del registro para que la
migracion pueda volver a aplicarse:

    python -m app.migrate --revertir 969_claves_de_reenvio.sql
    python -m app.migrate --revertir-ultima
    python -m app.migrate --revertir-ultima --dry-run

**En orden inverso.** Una migracion puede apoyarse en la anterior, asi que
revertir la 963 antes que la 967 puede fallar o dejar la base a medias. El
aplicador revierte de a una y `--revertir-ultima` siempre toma la ultima
aplicada, que es lo correcto.

**Algunos reverts pierden datos y lo dicen arriba.** Deshacer una columna
borra lo que esa columna guardaba, y no hay forma de que no sea asi. Los que
ademas chocarian con datos existentes, como un CHECK que se achica, no
borran nada por su cuenta: se detienen con un mensaje que explica que hay
que decidir primero.

La regla de que toda migracion de esquema nueva traiga su revert la
comprueba `tests/test_revertir.py`.

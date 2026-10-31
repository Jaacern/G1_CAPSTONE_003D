"""Tareas de mantenimiento del almacenamiento de archivos.

Por ahora hay una sola: cerrar las subidas que se pidieron y nunca llegaron.

Se corre desde afuera, no desde un request:

    python -m app.maintenance barrer-subidas

La idea es que quede en una tarea programada cada hora. No se expone como
endpoint a proposito: no es una accion de un usuario, no tiene a quien
responderle, y un endpoint de mantenimiento abierto es justo la clase de
puerta que uno no quiere tener en una aplicacion con datos de salud.
"""
from __future__ import annotations

import asyncio
import sys

from sqlalchemy import text

from app.db import engine
from app.storage import get_storage

# Margen despues del vencimiento antes de dar la subida por perdida. El
# enlace vence a los 15 minutos, pero el PUT puede estar en curso justo en
# ese momento: un PDF de 20 MB por el dato movil de la casa de un paciente
# tarda. Marcarlo vencido mientras los bytes van llegando seria arruinar una
# subida que iba bien.
GRACIA_MINUTOS = 30


async def barrer_subidas_vencidas(*, verbose: bool = True) -> dict[str, int]:
    """Marca expired las subidas que vencieron sin completarse.

    Devuelve cuantas filas se marcaron y cuantos binarios huerfanos se
    borraron del almacenamiento.

    Un binario huerfano es el caso raro pero posible de que el PUT haya
    guardado el archivo y la actualizacion de la fila haya fallado despues
    (se cayo la base, se corto el proceso). Queda un archivo en disco que
    nadie va a volver a nombrar nunca, porque su fila dice que no llego.
    Ese se borra: no es informacion, es basura que ocupa espacio.

    Las FILAS no se borran, solo cambian de estado. La constancia de que
    alguien intento subir algo al expediente de un paciente se conserva.
    """
    storage = get_storage()
    marcadas = 0
    huerfanos = 0

    async with engine.begin() as conn:
        vencidas = (
            await conn.execute(
                text(
                    """
                    SELECT id, storage_key
                    FROM files
                    WHERE status = 'pending'
                      AND upload_expires_at < now() - make_interval(mins => :gracia)
                    ORDER BY upload_expires_at
                    """
                ),
                {"gracia": GRACIA_MINUTOS},
            )
        ).mappings().all()

        for f in vencidas:
            # Primero el disco y despues la fila. Si se cae en medio, la fila
            # sigue pending y la proxima corrida la vuelve a tomar. Al reves
            # quedaria un binario que ya nadie puede nombrar.
            try:
                if storage.exists(storage_key=f["storage_key"]):
                    await storage.delete(storage_key=f["storage_key"])
                    huerfanos += 1
            except Exception as e:  # noqa: BLE001
                # Que un archivo no se pueda borrar no debe detener el
                # barrido de los otros cien.
                if verbose:
                    print(f"  no se pudo borrar {f['storage_key']}: {e}")

            await conn.execute(
                text(
                    """
                    UPDATE files
                       SET status = 'expired', updated_at = now()
                     WHERE id = :id AND status = 'pending'
                    """
                ),
                {"id": str(f["id"])},
            )
            marcadas += 1

    if verbose:
        print(f"subidas vencidas marcadas : {marcadas}")
        print(f"binarios huerfanos borrados: {huerfanos}")

    return {"marcadas": marcadas, "huerfanos": huerfanos}


async def _main(argv: list[str]) -> int:
    tareas = {"barrer-subidas": barrer_subidas_vencidas}
    if len(argv) != 1 or argv[0] not in tareas:
        print(f"uso: python -m app.maintenance <{' | '.join(tareas)}>")
        return 2
    try:
        await tareas[argv[0]]()
    finally:
        await engine.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(_main(sys.argv[1:])))

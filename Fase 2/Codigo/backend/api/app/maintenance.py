"""Tareas de mantenimiento que la aplicacion necesita que alguien corra.

Se corren desde afuera, no desde un request:

    python -m app.maintenance barrer-subidas
    python -m app.maintenance generar-dosis
    python -m app.maintenance marcar-vencidas

No se exponen como endpoints a proposito: no son acciones de un usuario,
no tienen a quien responderle, y un endpoint de mantenimiento abierto es
justo la clase de puerta que uno no quiere tener en una aplicacion con
datos de salud.
"""
from __future__ import annotations

import asyncio
import os
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

# Zona horaria de la operacion. medication_times guarda "las 8 de la manana"
# como hora local, no como instante, asi que para convertirla hace falta
# saber de que pais se habla. Se deja en una variable de entorno porque es
# lo unico de aca que cambiaria si manana el servicio opera en otro pais,
# pero el valor por defecto es el real: AgeCare opera en Chile.
ZONA = os.getenv("AGECARE_TIMEZONE", "America/Santiago")


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


async def generar_dosis(*, dias: int = 14, verbose: bool = True) -> dict[str, int]:
    """Crea las dosis programadas de los proximos dias.

    POR QUE HACE FALTA
        scheduled_doses es lo que la pantalla muestra como "lo que toca
        hoy" y es contra lo que se mide la adherencia. Nadie la llenaba.
        El medicamento guarda sus horas en medication_times y sus dias en
        medication_days, pero la fila concreta de "losartan, manana a las
        20:00" tiene que existir para que alguien pueda marcarla.

        Sin esto la pantalla de medicamentos sale vacia y la adherencia da
        cero, aunque los medicamentos esten bien cargados. El UNIQUE
        (medication_id, scheduled_at) de la tabla se escribio pensando en
        este proceso: dice "un slot por medicamento y hora".

    LA HORA
        time_of_day es hora chilena, no UTC. "Las 8 de la manana" no es un
        instante fijo: en enero son las 11:00 UTC y en julio las 12:00,
        porque Chile cambia la hora. Por eso la conversion la hace
        Postgres con AT TIME ZONE y no Python armando el instante a mano:
        asi la dosis cae a las 8 de la manana de la senora todo el anio,
        y no se corre una hora en marzo.

        Es la misma expresion que usa el seed. Si fuera distinta, las
        dosis generadas no chocarian con las sembradas y quedarian dos
        filas para la misma toma, a una hora de distancia.

    QUE NO HACE
        No toca ninguna fila existente. Lo unico que hace es insertar las
        que faltan, y ON CONFLICT DO NOTHING descarta las que ya estan.
        Correrlo dos veces seguidas, o todos los dias, es inofensivo: la
        segunda vez no crea nada. Tampoco hay que llevar la cuenta de
        hasta donde se genero.

        Se generan tambien los slots de hoy que ya pasaron. Si el proceso
        corre a mediodia, la toma de las 08:00 tiene que existir para
        poder quedar como no administrada; saltarsela seria borrar del
        historial una dosis que al paciente le tocaba.
    """
    async with engine.begin() as conn:
        r = await conn.execute(
            text(
                """
                INSERT INTO scheduled_doses (medication_id, scheduled_at, status)
                SELECT m.id,
                       (CAST(g.d AS date) + t.time_of_day)
                           AT TIME ZONE CAST(:zona AS text),
                       'pending'
                FROM medications m
                JOIN medication_times t ON t.medication_id = m.id
                CROSS JOIN generate_series(
                    CAST(now() AT TIME ZONE CAST(:zona AS text) AS date),
                    CAST(now() AT TIME ZONE CAST(:zona AS text) AS date)
                        + CAST(:dias AS integer),
                    interval '1 day'
                ) AS g(d)
                WHERE m.discontinued_at IS NULL
                  AND (m.start_date IS NULL OR CAST(g.d AS date) >= m.start_date)
                  AND (m.end_date   IS NULL OR CAST(g.d AS date) <= m.end_date)
                  -- Un medicamento sin dias declarados es de todos los dias:
                  -- es lo que asume medications.py cuando la pantalla no
                  -- manda ninguno (_DEFAULT_DAYS). Si aca se exigiera la
                  -- fila en medication_days, ese medicamento no generaria
                  -- dosis nunca y nadie entenderia por que.
                  AND (
                        NOT EXISTS (SELECT 1 FROM medication_days md
                                     WHERE md.medication_id = m.id)
                     OR EXISTS (SELECT 1 FROM medication_days md
                                 WHERE md.medication_id = m.id
                                   AND md.day_of_week = EXTRACT(isodow FROM g.d))
                  )
                ON CONFLICT (medication_id, scheduled_at) DO NOTHING
                """
            ),
            {"zona": ZONA, "dias": dias},
        )
        creadas = r.rowcount or 0

        vigentes = (
            await conn.execute(
                text(
                    """
                    SELECT count(DISTINCT m.id)
                    FROM medications m
                    JOIN medication_times t ON t.medication_id = m.id
                    WHERE m.discontinued_at IS NULL
                      AND (m.end_date IS NULL
                           OR m.end_date >= CAST(now() AT TIME ZONE CAST(:zona AS text)
                                                 AS date))
                    """
                ),
                {"zona": ZONA},
            )
        ).scalar() or 0

    if verbose:
        print(f"medicamentos vigentes : {vigentes}")
        print(f"dosis creadas         : {creadas}")
    return {"medicamentos": int(vigentes), "creadas": creadas}


async def _parametro(conn, clave: str, por_defecto: int) -> int:
    """Lee un umbral de negocio de system_parameters.

    Esos valores viven en la tabla justamente para poder cambiarlos sin
    redespliegue (lo dice el comentario de la tabla). Si falta la fila se
    usa el valor por defecto en vez de reventar: un proceso de
    mantenimiento que se cae porque alguien borro una fila de
    configuracion es peor que uno que sigue con el valor conocido.
    """
    v = (
        await conn.execute(
            text("SELECT value FROM system_parameters WHERE key = :k"),
            {"k": clave},
        )
    ).scalar()
    try:
        return int(v)
    except (TypeError, ValueError):
        return por_defecto


async def marcar_dosis_vencidas(*, verbose: bool = True) -> dict[str, int]:
    """Pasa a 'missed' las dosis cuyo plazo vencio sin que nadie las registre.

    POR QUE HACE FALTA
        Una dosis se crea 'pending' y ahi se queda para siempre si nadie
        la toca. La adherencia cuenta 'taken' contra 'missed' y 'skipped',
        asi que una toma que nunca se dio quedaba como pendiente y no
        bajaba la adherencia: el indicador mostraba 100% de un paciente al
        que no le dieron nada en tres dias. El semaforo tampoco se
        enteraba, porque mira las dosis 'missed' del dia.

    CUANTO SE ESPERA
        grace_window_min, del propio medicamento (una hora por defecto, y
        la pantalla deja ponerle entre 5 minutos y 4 horas). No es un
        numero global a proposito: a una insulina con horario estricto no
        se le puede dar el mismo margen que a una vitamina.

    LA DIFERENCIA CON MARCARLA A MANO
        Cuando la cuidadora marca una dosis como no administrada, el
        endpoint le exige un motivo y guarda quien y cuando. Aca no hay
        nadie, asi que logged_by y logged_at quedan en NULL, y eso es
        informacion y no un hueco: una dosis 'missed' con logged_by es
        "no se la di, por esto"; sin logged_by es "se paso la hora y nadie
        dijo nada". Son dos hechos distintos y conviene poder separarlos
        despues. Los CHECK de la tabla lo permiten: solo exigen logged_at
        para 'taken' y 'skipped'.

    LAS POSPUESTAS
        Una dosis pospuesta tiene su propio plazo, postponed_until, y se
        mide contra ese. Hoy la aplicacion no pospone nada, pero el
        endpoint lo acepta y la tabla lo guarda, asi que si alguna llega
        por ahi no se queda colgada para siempre.
    """
    async with engine.begin() as conn:
        r = await conn.execute(
            text(
                """
                UPDATE scheduled_doses sd
                   SET status = 'missed', updated_at = now()
                  FROM medications m
                 WHERE m.id = sd.medication_id
                   AND sd.status IN ('pending', 'postponed')
                   AND coalesce(sd.postponed_until, sd.scheduled_at)
                       + make_interval(mins => m.grace_window_min) < now()
                """
            )
        )
        marcadas = r.rowcount or 0

    if verbose:
        print(f"dosis vencidas marcadas : {marcadas}")
    return {"marcadas": marcadas}


async def _main(argv: list[str]) -> int:
    tareas = {"barrer-subidas": barrer_subidas_vencidas,
              "generar-dosis": generar_dosis,
              "marcar-vencidas": marcar_dosis_vencidas}
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

"""Pruebas del generador de dosis programadas.

Contra el modelo de tratamientos. El generador tiene dos origenes mientras
conviven los dos modelos: medications, para los pacientes que todavia no
fueron migrados, y treatment_items, para los que ya tienen un tratamiento
vigente. El paciente de prueba quedo migrado por 960_migrate_treatments, asi
que sus dosis salen del segundo, y es ese el que se prueba.
"""
import asyncio, os, sys
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")

# El paquete app vive un nivel mas arriba, en backend/api. Sin esta linea,
# ejecutar "python tests/test_x.py" deja solo tests/ en el path de busqueda y
# el import de app falla. Va aqui arriba, junto a las variables de entorno,
# porque tiene que pasar antes de importar cualquier cosa de la aplicacion.
import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))


from sqlalchemy import text
from app.db import engine
from app.maintenance import generar_dosis, ZONA

ok = fallo = 0
def check(nombre, cond, detalle=""):
    global ok, fallo
    if cond: ok += 1; print(f"  ok   {nombre}")
    else:    fallo += 1; print(f"  FALLA {nombre} {detalle}")

PACIENTE = "33333333-3333-4333-8333-333333333333"

# El dia local, que es el que manda: la dosis de las 20:00 pertenece al dia
# chileno, no al dia UTC en que cae ese instante.
HOY   = f"CAST(now() AT TIME ZONE '{ZONA}' AS date)"
DIA   = f"CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date)"
FUTURO = f"{DIA} > {HOY}"


async def borrar_futuras(c, item):
    await c.execute(text(
        f"DELETE FROM scheduled_doses WHERE treatment_item_id = :i AND {FUTURO}"),
        {"i": item})


async def cuantas_futuras(c, item):
    return (await c.execute(text(
        f"SELECT count(*) FROM scheduled_doses WHERE treatment_item_id = :i "
        f"  AND {FUTURO}"), {"i": item})).scalar()


async def main():
    global fallo
    async with engine.begin() as c:
        # El id del item no se puede escribir a mano: lo crea la migracion con
        # gen_random_uuid. Se busca por nombre dentro del tratamiento vigente
        # del paciente, que es como lo encontraria la pantalla.
        item = (await c.execute(text(
            "SELECT ti.id FROM treatment_items ti "
            "JOIN treatments tr ON tr.id = ti.treatment_id "
            "WHERE tr.patient_id = :p AND tr.status = 'vigente' "
            "  AND ti.name LIKE 'Losart%'"), {"p": PACIENTE})).scalar()
        check("el paciente tiene un tratamiento vigente con el farmaco",
              item is not None)
        if item is None:
            print("\n0 ok, 1 fallas")
            return 1
        item = str(item)
        tratamiento = (await c.execute(text(
            "SELECT treatment_id FROM treatment_items WHERE id = :i"),
            {"i": item})).scalar()
        desde = (await c.execute(text(
            "SELECT effective_from FROM treatments WHERE id = :t"),
            {"t": tratamiento})).scalar()

        antes = (await c.execute(text("SELECT count(*) FROM scheduled_doses"))).scalar()
        # Se borran los slots futuros para que haya algo que generar. Antes
        # la prueba daba por hecho que faltaban, y pasaba o fallaba segun
        # que prueba hubiera corrido antes, que es justo lo que una prueba
        # no puede hacer.
        await c.execute(text(
            f"DELETE FROM scheduled_doses WHERE status = 'pending' AND {FUTURO}"))
        # Foto de las filas existentes, para probar que no se tocan. Van las
        # dos columnas de origen: una dosis puede venir de medications o de
        # treatment_items, y la prueba no debe dejar de ver las de un origen.
        foto = (await c.execute(text(
            "SELECT id, medication_id, treatment_item_id, scheduled_at, status, "
            "  administered_at FROM scheduled_doses "
            "ORDER BY medication_id, treatment_item_id, scheduled_at"))).all()

    r1 = await generar_dosis(dias=14, verbose=False)
    check("crea las dosis que faltaban", r1["creadas"] > 0,
          f"creadas={r1['creadas']}")

    # Idempotencia: la segunda corrida no debe crear nada.
    r2 = await generar_dosis(dias=14, verbose=False)
    check("es idempotente", r2["creadas"] == 0, f"creadas={r2['creadas']}")

    async with engine.begin() as c:
        # Ninguna fila anterior cambio ni desaparecio.
        foto2 = {(str(f[0])): f for f in (await c.execute(text(
            "SELECT id, medication_id, treatment_item_id, scheduled_at, status, "
            "  administered_at FROM scheduled_doses"))).all()}
        intactas = all(str(f[0]) in foto2 and foto2[str(f[0])] == f for f in foto)
        check("no toca las filas existentes", intactas)

        # Las horas caen donde la senora las espera. Las horas declaradas del
        # item tienen que estar, y las generadas tienen que caer en ellas. Se
        # compara contra treatment_item_times y no contra una lista escrita a
        # mano, que quedaria mintiendo el dia que el seed cambie.
        declaradas = (await c.execute(text(
            "SELECT to_char(time_of_day, 'HH24:MI') FROM treatment_item_times "
            "WHERE treatment_item_id = :i ORDER BY 1"), {"i": item})).scalars().all()
        horas = (await c.execute(text(
            f"SELECT DISTINCT to_char(scheduled_at AT TIME ZONE '{ZONA}', 'HH24:MI') "
            f"FROM scheduled_doses WHERE treatment_item_id = :i AND {FUTURO} "
            "ORDER BY 1"), {"i": item})).scalars().all()
        check("respeta la hora local", list(horas) == list(declaradas),
              (list(horas), list(declaradas)))

        # Cubre desde hoy hasta hoy+14, ambos incluidos.
        rango = (await c.execute(text(
            f"SELECT min({DIA}), max({DIA}), {HOY} "
            "FROM scheduled_doses WHERE treatment_item_id = :i"),
            {"i": item})).first()
        check("llega hasta hoy+14", (rango[1] - rango[2]).days == 14, rango)

        # Un slot por horario declarado y por dia, los 14 dias siguientes a
        # hoy. Se cuentan solo los que caen en un horario declarado: otra
        # prueba puede haber dejado una dosis a una hora cualquiera, y eso no
        # dice nada de este proceso.
        n = (await c.execute(text(
            f"SELECT count(*) FROM scheduled_doses sd "
            f"WHERE sd.treatment_item_id = :i "
            f"  AND CAST(sd.scheduled_at AT TIME ZONE '{ZONA}' AS date) > {HOY} "
            f"  AND EXISTS (SELECT 1 FROM treatment_item_times t "
            f"               WHERE t.treatment_item_id = sd.treatment_item_id "
            f"                 AND t.time_of_day = CAST(sd.scheduled_at "
            f"                     AT TIME ZONE '{ZONA}' AS time))"),
            {"i": item})).scalar()
        check("un slot por horario y por dia durante 14 dias",
              n == 14 * len(declaradas), (n, len(declaradas)))

    # --- Una indicacion retirada del tratamiento no genera nada nuevo ---
    async with engine.begin() as c:
        await c.execute(text("UPDATE treatment_items SET action = 'removed' "
                             "WHERE id = :i"), {"i": item})
        await borrar_futuras(c, item)
    await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        check("una indicacion retirada no genera agenda",
              await cuantas_futuras(c, item) == 0)
        await c.execute(text("UPDATE treatment_items SET action = 'kept' "
                             "WHERE id = :i"), {"i": item})

    # --- Una indicacion SOS tampoco ---
    # Es la diferencia de fondo entre un SOS y una indicacion de horario: el
    # SOS se usa si hace falta y se registra al usarse, asi que no puede
    # aparecer como dosis pendiente ni contar en la adherencia.
    async with engine.begin() as c:
        await c.execute(text("UPDATE treatment_items SET is_prn = true "
                             "WHERE id = :i"), {"i": item})
        await borrar_futuras(c, item)
    await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        check("una indicacion SOS no genera agenda",
              await cuantas_futuras(c, item) == 0)
        await c.execute(text("UPDATE treatment_items SET is_prn = false, "
                             "  prn_min_interval_min = NULL WHERE id = :i"),
                        {"i": item})

    # --- Un tratamiento que ya no esta vigente tampoco ---
    async with engine.begin() as c:
        await c.execute(text("UPDATE treatments SET status = 'superseded', "
                             "  effective_to = now() WHERE id = :t"),
                        {"t": tratamiento})
        await borrar_futuras(c, item)
    await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        check("un tratamiento superado no genera agenda",
              await cuantas_futuras(c, item) == 0)
        await c.execute(text("UPDATE treatments SET status = 'vigente', "
                             "  effective_to = NULL WHERE id = :t"),
                        {"t": tratamiento})

    # --- Nada antes de que el tratamiento empiece a regir ---
    async with engine.begin() as c:
        await c.execute(text(
            "UPDATE treatments SET effective_from = now() + interval '3 days' "
            "WHERE id = :t"), {"t": tratamiento})
        await borrar_futuras(c, item)
    await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        primera = (await c.execute(text(
            f"SELECT min({DIA}) - {HOY} FROM scheduled_doses "
            f"WHERE treatment_item_id = :i AND {FUTURO}"), {"i": item})).scalar()
        check("no agenda antes de que el tratamiento rija", primera == 3, primera)
        await c.execute(text("UPDATE treatments SET effective_from = :d "
                             "WHERE id = :t"), {"d": desde, "t": tratamiento})

    # --- Solo los dias declarados: se deja el farmaco los lunes ---
    async with engine.begin() as c:
        await c.execute(text("DELETE FROM treatment_item_days "
                             "WHERE treatment_item_id = :i AND day_of_week <> 1"),
                        {"i": item})
        await borrar_futuras(c, item)
    await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        dias = (await c.execute(text(
            f"SELECT DISTINCT EXTRACT(isodow FROM scheduled_at AT TIME ZONE '{ZONA}') "
            f"FROM scheduled_doses WHERE treatment_item_id = :i AND {FUTURO}"),
            {"i": item})).scalars().all()
        check("solo los dias declarados", [int(d) for d in dias] == [1], list(dias))

        # Sin ningun dia declarado se entiende todos los dias. Es lo que asume
        # el editor cuando la pantalla no manda ninguno: si aca se exigiera la
        # fila, ese item no generaria dosis nunca y nadie entenderia por que.
        await c.execute(text("DELETE FROM treatment_item_days "
                             "WHERE treatment_item_id = :i"), {"i": item})
        await borrar_futuras(c, item)
    await generar_dosis(dias=6, verbose=False)
    async with engine.begin() as c:
        dias = (await c.execute(text(
            f"SELECT count(DISTINCT {DIA}) FROM scheduled_doses "
            f"WHERE treatment_item_id = :i AND {FUTURO}"), {"i": item})).scalar()
        check("sin dias declarados genera todos los dias", dias == 6, dias)
        # Se repone el seed.
        await c.execute(text(
            "INSERT INTO treatment_item_days (treatment_item_id, day_of_week) "
            "SELECT :i, g FROM generate_series(1,7) g "
            "ON CONFLICT DO NOTHING"), {"i": item})

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas  (habia {antes} dosis, se crearon {r1['creadas']})")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

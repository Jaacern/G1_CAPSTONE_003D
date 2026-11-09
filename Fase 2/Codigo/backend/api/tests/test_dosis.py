"""Pruebas del generador de dosis programadas."""
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

LOSARTAN = "77777777-7777-4777-8777-777777777777"

async def main():
    global fallo
    async with engine.begin() as c:
        antes = (await c.execute(text("SELECT count(*) FROM scheduled_doses"))).scalar()
        # Se borran los slots futuros para que haya algo que generar. Antes
        # la prueba daba por hecho que faltaban, y pasaba o fallaba segun
        # que prueba hubiera corrido antes, que es justo lo que una prueba
        # no puede hacer.
        await c.execute(text(
            f"DELETE FROM scheduled_doses WHERE status = 'pending' "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"))
        # Foto de las filas existentes, para probar que no se tocan.
        foto = (await c.execute(text(
            "SELECT id, medication_id, scheduled_at, status, administered_at "
            "FROM scheduled_doses ORDER BY medication_id, scheduled_at"))).all()

    r1 = await generar_dosis(dias=14, verbose=False)
    check("crea las dosis que faltaban", r1["creadas"] > 0,
          f"creadas={r1['creadas']}")
    check("cuenta los medicamentos vigentes", r1["medicamentos"] == 2, r1)

    # Idempotencia: la segunda corrida no debe crear nada.
    r2 = await generar_dosis(dias=14, verbose=False)
    check("es idempotente", r2["creadas"] == 0, f"creadas={r2['creadas']}")

    async with engine.begin() as c:
        # Ninguna fila anterior cambio ni desaparecio.
        foto2 = {(str(f[0])): f for f in (await c.execute(text(
            "SELECT id, medication_id, scheduled_at, status, administered_at "
            "FROM scheduled_doses"))).all()}
        intactas = all(str(f[0]) in foto2 and foto2[str(f[0])] == f for f in foto)
        check("no toca las filas existentes", intactas)

        # Las horas caen donde la senora las espera: 08:00 y 20:00 de Chile.
        # Las horas declaradas del medicamento tienen que estar, y las
        # generadas tienen que caer en ellas. Se compara contra
        # medication_times y no contra una lista escrita a mano, que
        # quedaria mintiendo el dia que el seed cambie.
        declaradas = (await c.execute(text(
            "SELECT to_char(time_of_day, 'HH24:MI') FROM medication_times "
            "WHERE medication_id = :m ORDER BY 1"), {"m": LOSARTAN})).scalars().all()
        horas = (await c.execute(text(
            f"SELECT DISTINCT to_char(scheduled_at AT TIME ZONE '{ZONA}', 'HH24:MI') "
            "FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date) ORDER BY 1"),
            {"m": LOSARTAN})).scalars().all()
        check("respeta la hora local", list(horas) == list(declaradas),
              (list(horas), list(declaradas)))

        # Cubre desde hoy hasta hoy+14, ambos incluidos.
        rango = (await c.execute(text(
            f"SELECT min(CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date)), "
            f"       max(CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date)), "
            f"       CAST(now() AT TIME ZONE '{ZONA}' AS date) "
            "FROM scheduled_doses WHERE medication_id = :m"),
            {"m": LOSARTAN})).first()
        check("llega hasta hoy+14", (rango[1] - rango[2]).days == 14, rango)

        # Un slot por horario declarado y por dia, los 14 dias siguientes
        # a hoy. Se cuentan solo los que caen en un horario declarado: otra
        # prueba puede haber dejado una dosis a una hora cualquiera, y eso
        # no dice nada de este proceso.
        n = (await c.execute(text(
            f"SELECT count(*) FROM scheduled_doses sd "
            f"WHERE sd.medication_id = :m "
            f"  AND CAST(sd.scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date) "
            f"  AND EXISTS (SELECT 1 FROM medication_times t "
            f"               WHERE t.medication_id = sd.medication_id "
            f"                 AND t.time_of_day = CAST(sd.scheduled_at "
            f"                     AT TIME ZONE '{ZONA}' AS time))"),
            {"m": LOSARTAN})).scalar()
        check("un slot por horario y por dia durante 14 dias",
              n == 14 * len(declaradas), (n, len(declaradas)))

        # Un medicamento suspendido no genera nada nuevo.
        await c.execute(text("UPDATE medications SET discontinued_at = now() "
                             "WHERE id = :m"), {"m": LOSARTAN})
    # Se borran los slots futuros del suspendido para ver si los vuelve a crear.
    async with engine.begin() as c:
        await c.execute(text(
            f"DELETE FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"), {"m": LOSARTAN})
    r3 = await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        quedaron = (await c.execute(text(
            f"SELECT count(*) FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"),
            {"m": LOSARTAN})).scalar()
        check("ignora los medicamentos suspendidos", quedaron == 0, quedaron)
        check("sigue contando solo los vigentes", r3["medicamentos"] == 1, r3)
        await c.execute(text("UPDATE medications SET discontinued_at = NULL "
                             "WHERE id = :m"), {"m": LOSARTAN})

        # Un medicamento que termino ayer tampoco.
        await c.execute(text(
            f"UPDATE medications SET end_date = "
            f"  CAST(now() AT TIME ZONE '{ZONA}' AS date) - 1 WHERE id = :m"),
            {"m": LOSARTAN})
    async with engine.begin() as c:
        await c.execute(text(
            f"DELETE FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"), {"m": LOSARTAN})
    await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        quedaron = (await c.execute(text(
            f"SELECT count(*) FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"),
            {"m": LOSARTAN})).scalar()
        check("respeta end_date", quedaron == 0, quedaron)

        # Solo los dias declarados: se deja el losartan los lunes.
        await c.execute(text("UPDATE medications SET end_date = NULL WHERE id = :m"),
                        {"m": LOSARTAN})
        await c.execute(text("DELETE FROM medication_days WHERE medication_id = :m "
                             "AND day_of_week <> 1"), {"m": LOSARTAN})
    async with engine.begin() as c:
        await c.execute(text(
            f"DELETE FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"), {"m": LOSARTAN})
    await generar_dosis(dias=14, verbose=False)
    async with engine.begin() as c:
        dias = (await c.execute(text(
            f"SELECT DISTINCT EXTRACT(isodow FROM scheduled_at AT TIME ZONE '{ZONA}') "
            f"FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"),
            {"m": LOSARTAN})).scalars().all()
        check("solo los dias declarados", [int(d) for d in dias] == [1], list(dias))

        # Sin ningun dia declarado se entiende todos los dias.
        await c.execute(text("DELETE FROM medication_days WHERE medication_id = :m"),
                        {"m": LOSARTAN})
    async with engine.begin() as c:
        await c.execute(text(
            f"DELETE FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"), {"m": LOSARTAN})
    await generar_dosis(dias=6, verbose=False)
    async with engine.begin() as c:
        dias = (await c.execute(text(
            f"SELECT count(DISTINCT CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date)) "
            f"FROM scheduled_doses WHERE medication_id = :m "
            f"  AND CAST(scheduled_at AT TIME ZONE '{ZONA}' AS date) "
            f"      > CAST(now() AT TIME ZONE '{ZONA}' AS date)"),
            {"m": LOSARTAN})).scalar()
        check("sin dias declarados genera todos los dias", dias == 6, dias)
        # Se repone el seed.
        await c.execute(text(
            "INSERT INTO medication_days (medication_id, day_of_week) "
            "SELECT :m, g FROM generate_series(1,7) g "
            "ON CONFLICT DO NOTHING"), {"m": LOSARTAN})

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas  (habia {antes} dosis, se crearon {r1['creadas']})")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

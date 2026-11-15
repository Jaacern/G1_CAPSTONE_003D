"""Pruebas de la zona horaria de la conexion.

El error que esto cubre no se ve a mediodia: solo aparece en las horas en
que la fecha UTC y la chilena no coinciden. Asi que las pruebas no miran
la hora actual, miran instantes elegidos a proposito en ese borde.
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


from datetime import datetime, time, timedelta, timezone as tz
from zoneinfo import ZoneInfo

from sqlalchemy import text
from app.config import get_settings
from app.db import engine, SessionLocal
from app.fechas import ahora, hoy, instante, zona as _zona
from app.routers.logbook import _turno_de
from app.routers.vitals import _medications_today

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

PAC = "33333333-3333-4333-8333-333333333333"
MED = "77777777-7777-4777-8777-777777777777"
MARCA = "FIXTURE-ZONA"

async def main():
    zona = get_settings().timezone
    check("la zona esta configurada", zona == "America/Santiago", zona)

    async with engine.begin() as c:
        check("la conexion abre con la zona puesta",
              (await c.execute(text("SHOW timezone"))).scalar() == zona)

        # Un instante de las 02:00 UTC es del dia anterior en Chile. Es el
        # caso exacto que estaba mal: la fecha se decidia en UTC.
        dia = (await c.execute(text(
            "SELECT CAST(CAST('2026-11-01 02:00:00+00' AS timestamptz) AS date)"
        ))).scalar()
        check("un instante de madrugada UTC pertenece al dia chileno anterior",
              dia.isoformat() == "2026-10-31", dia)

        # Y el de las 23:00 UTC sigue siendo del mismo dia chileno.
        dia = (await c.execute(text(
            "SELECT CAST(CAST('2026-11-01 23:00:00+00' AS timestamptz) AS date)"
        ))).scalar()
        check("un instante de la noche UTC sigue en el dia chileno",
              dia.isoformat() == "2026-11-01", dia)

        # current_date y la fecha local tienen que ser la misma siempre.
        igual = (await c.execute(text(
            "SELECT current_date = CAST(now() AT TIME ZONE :z AS date)"),
            {"z": zona})).scalar()
        check("current_date es el dia chileno", igual is True)

        # Comparar instantes no cambia: timestamptz sigue siendo absoluto.
        antes = (await c.execute(text(
            "SELECT CAST('2026-11-01 02:00:00+00' AS timestamptz) "
            "     < CAST('2026-11-01 03:00:00+00' AS timestamptz)"))).scalar()
        check("el orden entre instantes no se toca", antes is True)

        await c.execute(text("DELETE FROM scheduled_doses WHERE reason = :r"),
                        {"r": MARCA})
        # Una dosis a las 22:00 de hoy en Chile. El instante se arma en
        # Python y no con current_date: si se armara en SQL se moveria con
        # la zona de la sesion y la prueba pasaria igual estando mal, que
        # es lo que hacia antes.
        hoy_cl = datetime.now(ZoneInfo(zona)).date()
        noche = datetime.combine(hoy_cl, time(22, 0), tzinfo=ZoneInfo(zona))
        check("ese instante cae en otro dia en UTC",
              noche.astimezone(tz.utc).date() != hoy_cl,
              (noche.isoformat(), noche.astimezone(tz.utc).isoformat()))
    # El conteo se mide antes y despues: lo que importa es que ESA dosis
    # entre, no que haya alguna pendiente hoy, que la hay de todos modos.
    async with SessionLocal() as db:
        antes = (await _medications_today(db, PAC)).pending
    async with engine.begin() as c:
        await c.execute(text(
            "INSERT INTO scheduled_doses (medication_id, scheduled_at, status, "
            "  reason) VALUES (:m, :t, 'pending', :r)"),
            {"m": MED, "t": noche, "r": MARCA})

    async with SessionLocal() as db:
        meds = await _medications_today(db, PAC)
    check("la pantalla cuenta la dosis de las 22:00 como de hoy",
          meds.pending == antes + 1, (antes, meds.pending))
    check("y le queda una proxima dosis del dia",
          meds.next_dose is not None, meds)

    async with engine.begin() as c:
        await c.execute(text("DELETE FROM scheduled_doses WHERE reason = :r"),
                        {"r": MARCA})

    # --- El modulo de fechas ---
    check("la zona del modulo es la configurada", _zona().key == zona, _zona().key)
    async with engine.begin() as c:
        dia_bd = (await c.execute(text("SELECT current_date"))).scalar()
    check("hoy() coincide con el dia de la base", hoy() == dia_bd,
          (hoy(), dia_bd))
    check("ahora() viene con zona, no suelto", ahora().tzinfo is not None)

    # instante() tiene que dar la medianoche chilena, que en UTC es de la
    # tarde del dia anterior. Es el corte que usa "las observaciones de hoy".
    medianoche = instante(hoy())
    check("instante() da la medianoche local",
          medianoche.hour == 0 and medianoche.minute == 0, medianoche)
    async with engine.begin() as c:
        mismo = (await c.execute(text(
            "SELECT CAST(CAST(:t AS timestamptz) AS date) = current_date"),
            {"t": medianoche})).scalar()
    check("la medianoche local pertenece al dia de hoy", mismo is True)
    # Lo que estaba mal era lo contrario: marcar la medianoche como UTC.
    # Esa medianoche UTC es las 20:00 o 21:00 del dia ANTERIOR en Chile, asi
    # que "las observaciones de hoy" incluian tres horas de ayer.
    como_estaba = datetime.combine(hoy(), time.min, tzinfo=tz.utc)
    check("la medianoche UTC caia en el dia anterior en Chile",
          como_estaba.astimezone(_zona()).date() == hoy() - timedelta(days=1),
          como_estaba.astimezone(_zona()).isoformat())
    check("y la local no", medianoche.astimezone(_zona()).date() == hoy())

    # Una hora de pared se devuelve como la hora que es, no corrida.
    i = instante(hoy(), time(9, 30))
    check("instante() no corre la hora de pared",
          (i.hour, i.minute) == (9, 30), i.isoformat())
    check("y en UTC esa hora ya no son las 9:30",
          i.astimezone(tz.utc).hour != 9, i.astimezone(tz.utc).isoformat())

    # --- El turno se deduce de la hora de la pared, no de la UTC ---
    # Los cortes del codigo (7 a 15, 15 a 23) estan escritos en hora
    # chilena. Leidos en UTC salian corridos tres horas: estos son los
    # cuatro casos donde se notaba.
    def turno_a_las(h):
        return _turno_de(instante(hoy(), time(h)))
    check("la una de la tarde es turno de manana", turno_a_las(13) == "morning",
          turno_a_las(13))
    check("las cinco de la madrugada son turno de noche",
          turno_a_las(5) == "night", turno_a_las(5))
    check("las siete abren el turno de manana",
          turno_a_las(7) == "morning", turno_a_las(7))
    check("las tres de la tarde abren el de tarde",
          turno_a_las(15) == "afternoon", turno_a_las(15))
    check("las once de la noche abren el de noche",
          turno_a_las(23) == "night", turno_a_las(23))

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

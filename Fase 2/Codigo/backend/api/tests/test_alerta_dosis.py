"""Pruebas de la alerta por dosis no administrada."""
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
from app.maintenance import alertar_dosis_omitidas

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

MED = "77777777-7777-4777-8777-777777777777"
CUIDADORA = "22222222-2222-4222-8222-222222222222"

async def limpiar(c):
    """Borra lo que crea la prueba, al entrar y al salir."""
    await c.execute(text(
        "DELETE FROM alerts WHERE payload ->> 'prueba' = 'dosis' "
        "   OR payload ->> 'dose_id' IN ("
        "      SELECT CAST(id AS text) FROM scheduled_doses "
        "       WHERE reason = 'FIXTURE')"))
    await c.execute(text("DELETE FROM scheduled_doses WHERE reason = 'FIXTURE'"))

async def dosis(c, minutos, **extra):
    cols = {"medication_id": MED, "status": "missed", "reason": "FIXTURE", **extra}
    n = ", ".join(cols); v = ", ".join(f":{k}" for k in cols)
    return str((await c.execute(
        text(f"INSERT INTO scheduled_doses ({n}, scheduled_at) VALUES ({v}, "
             "now() - make_interval(mins => :min)) RETURNING id"),
        {**cols, "min": minutos})).scalar())

async def main():
    async with engine.begin() as c:
        await limpiar(c)
        # La ventana se apaga: la prueba mira dosis una por una, no el
        # frenado, que se prueba aparte mas abajo.
        await c.execute(text("UPDATE system_parameters SET value = '0' "
                             "WHERE key = 'alert_dedup_minutes'"))
    # Primero se drenan las dosis que ya venian sin alerta, para que el
    # conteo de la prueba cuente solo lo que la prueba creo.
    await alertar_dosis_omitidas(verbose=False)
    async with engine.begin() as c:
        d1 = await dosis(c, 300)
        d2 = await dosis(c, 290)
        # Marcada a mano por la cuidadora: no lleva alerta.
        d3 = str((await c.execute(text(
            "INSERT INTO scheduled_doses (medication_id, scheduled_at, status, "
            "  reason, logged_by, logged_at) VALUES (:m, "
            "  now() - make_interval(mins => 280), 'missed', 'FIXTURE', :u, now()) "
            "RETURNING id"), {"m": MED, "u": CUIDADORA})).scalar())
        # Una pendiente cualquiera: no es missed, no lleva alerta.
        d4 = await dosis(c, 10, status="pending")

    r = await alertar_dosis_omitidas(verbose=False)
    check("crea una alerta por dosis", r["creadas"] == 2, r)

    async with engine.begin() as c:
        async def alerta_de(fid):
            return (await c.execute(text(
                "SELECT type, severity, title, detail, dedup_key, status, payload "
                "FROM alerts WHERE payload ->> 'dose_id' = :i"),
                {"i": fid})).mappings().all()

        a = await alerta_de(d1)
        check("una sola alerta para esa dosis", len(a) == 1, len(a))
        if a:
            a = a[0]
            check("tipo y severidad", a["type"] == "missed_dose"
                  and a["severity"] == "warning", dict(a))
            check("nace activa", a["status"] == "active", a["status"])
            check("titulo del catalogo", a["title"] == "Dosis no administrada",
                  a["title"])
            check("detalle con medicamento, dosis y hora",
                  a["detail"].startswith("Losartán 50 mg de las ")
                  and a["detail"].endswith(" sin registro."), a["detail"])
            check("dedup_key de la convencion", a["dedup_key"] == "missed_dose")
            check("payload apunta a la dosis y al medicamento",
                  a["payload"]["dose_id"] == d1
                  and a["payload"]["medication_id"] == MED, a["payload"])

        check("no alerta la marcada por la cuidadora", len(await alerta_de(d3)) == 0)
        check("no alerta una pendiente", len(await alerta_de(d4)) == 0)

    # Idempotencia: la dosis ya tiene alerta, no se crea otra.
    r2 = await alertar_dosis_omitidas(verbose=False)
    check("es idempotente", r2["creadas"] == 0, r2)
    async with engine.begin() as c:
        check("sigue habiendo una sola alerta por dosis",
              (await c.execute(text(
                  "SELECT count(*) FROM alerts WHERE payload ->> 'dose_id' = :i"),
                  {"i": d1})).scalar() == 1)

        # Con la ventana puesta, una dosis nueva espera en vez de alertar.
        await c.execute(text("UPDATE system_parameters SET value = '30' "
                             "WHERE key = 'alert_dedup_minutes'"))
        d5 = await dosis(c, 270)
    r3 = await alertar_dosis_omitidas(verbose=False)
    check("la ventana frena el aviso", r3["creadas"] == 0 and r3["en_espera"] == 1, r3)

    async with engine.begin() as c:
        # Pero no lo pierde: con la ventana cumplida se crea igual.
        await c.execute(text(
            "UPDATE alerts SET created_at = now() - interval '2 hours' "
            "WHERE dedup_key = 'missed_dose'"))
    r4 = await alertar_dosis_omitidas(verbose=False)
    check("pasada la ventana lo crea, no lo descarta", r4["creadas"] == 1, r4)
    async with engine.begin() as c:
        check("la dosis que espero quedo con su alerta",
              (await c.execute(text(
                  "SELECT count(*) FROM alerts WHERE payload ->> 'dose_id' = :i"),
                  {"i": d5})).scalar() == 1)
        await limpiar(c)

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

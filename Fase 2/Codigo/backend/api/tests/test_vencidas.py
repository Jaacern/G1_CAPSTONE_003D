"""Pruebas del barrido de dosis vencidas."""
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
from app.maintenance import marcar_dosis_vencidas

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

MED = "77777777-7777-4777-8777-777777777777"
CUIDADORA = "22222222-2222-4222-8222-222222222222"
# Las filas de la prueba se marcan en reason y se borran por ahi. Antes se
# borraban por lista de ids, que no coincidian: eran strings contra una
# columna uuid, no borraba nada y la corrida ensuciaba la siguiente.
MARCA = "FIXTURE-VENCIDAS"


async def limpiar(c):
    await c.execute(text("DELETE FROM scheduled_doses WHERE reason = :r"),
                    {"r": MARCA})

async def slot(conn, minutos_atras, status="pending", **extra):
    """Crea una dosis a N minutos en el pasado (o futuro si es negativo)."""
    cols = {"medication_id": MED, "status": status, "reason": MARCA, **extra}
    nombres = ", ".join(cols) + ", scheduled_at"
    valores = ", ".join(f":{k}" for k in cols) + \
              ", now() - make_interval(mins => :min)"
    fid = (await conn.execute(
        text(f"INSERT INTO scheduled_doses ({nombres}) VALUES ({valores}) "
             "RETURNING id"),
        {**{k: str(v) if k.endswith("_id") or k.endswith("_by") else v
            for k, v in cols.items()}, "min": minutos_atras})).scalar()
    return str(fid)

async def estado(conn, fid):
    return (await conn.execute(text(
        "SELECT status, logged_by, logged_at, reason FROM scheduled_doses "
        "WHERE id = :i"), {"i": fid})).mappings().first()

async def main():
    async with engine.begin() as c:
        await limpiar(c)
        gracia = (await c.execute(text(
            "SELECT grace_window_min FROM medications WHERE id = :m"),
            {"m": MED})).scalar()
        check("el medicamento tiene margen configurado", gracia and gracia > 0, gracia)

        # Vencida de sobra.
        vencida  = await slot(c, gracia + 120)
        # Dentro del margen: no se toca todavia.
        a_tiempo = await slot(c, max(gracia - 5, 1))
        # Futura.
        futura   = await slot(c, -600)
    async with engine.begin() as c:
        # Ya registrada por alguien: intocable.
        tomada = (await c.execute(text(
            "INSERT INTO scheduled_doses (medication_id, scheduled_at, status, "
            "  administered_at, logged_by, logged_at,"
            "  reason) VALUES (:m, now() - make_interval(mins => :min), "
            "  'taken', now() - make_interval(mins => :min), :u, now(), :r) "
            "RETURNING id"),
            {"m": MED, "min": gracia + 300, "u": CUIDADORA, "r": MARCA})).scalar()
        tomada = str(tomada)
        # Omitida a mano, con motivo: tampoco se toca.
        omitida = (await c.execute(text(
            "INSERT INTO scheduled_doses (medication_id, scheduled_at, status, "
            "  reason, logged_by, logged_at) "
            "VALUES (:m, now() - make_interval(mins => :min), 'skipped', "
            "  :r, :u, now()) RETURNING id"),
            {"m": MED, "min": gracia + 400, "u": CUIDADORA, "r": MARCA})).scalar()
        omitida = str(omitida)
        # Pospuesta con plazo ya pasado y plazo aun vigente.
        pos_vencida = (await c.execute(text(
            "INSERT INTO scheduled_doses (medication_id, scheduled_at, status, "
            "  postponed_until, reason) VALUES (:m, now() - make_interval(mins => :s), "
            "  'postponed', now() - make_interval(mins => :p), :r) RETURNING id"),
            {"m": MED, "s": 300, "p": 180, "r": MARCA})).scalar()
        pos_vencida = str(pos_vencida)
        pos_vigente = (await c.execute(text(
            "INSERT INTO scheduled_doses (medication_id, scheduled_at, status, "
            "  postponed_until, reason) VALUES (:m, now() - make_interval(mins => :s), "
            "  'postponed', now() - make_interval(mins => 1), :r) RETURNING id"),
            {"m": MED, "s": 100, "r": MARCA})).scalar()
        pos_vigente = str(pos_vigente)

    r = await marcar_dosis_vencidas(verbose=False)
    check("marca algo", r["marcadas"] >= 2, r)

    async with engine.begin() as c:
        v = await estado(c, vencida)
        check("marca la vencida", v["status"] == "missed", dict(v))
        check("sin quien ni cuando, que es el dato", 
              v["logged_by"] is None and v["logged_at"] is None, dict(v))
        check("sin motivo inventado", v["reason"] == MARCA, dict(v))

        check("respeta el margen", (await estado(c, a_tiempo))["status"] == "pending")
        check("no toca las futuras", (await estado(c, futura))["status"] == "pending")

        t = await estado(c, tomada)
        check("no toca una dosis ya administrada",
              t["status"] == "taken" and str(t["logged_by"]) == CUIDADORA, dict(t))
        o = await estado(c, omitida)
        check("no pisa la omision con motivo de la cuidadora",
              o["status"] == "skipped" and str(o["logged_by"]) == CUIDADORA,
              dict(o))

        check("mide la pospuesta contra su propio plazo",
              (await estado(c, pos_vencida))["status"] == "missed")
        check("deja la pospuesta cuyo plazo no vence",
              (await estado(c, pos_vigente))["status"] == "postponed")

    # Idempotencia.
    r2 = await marcar_dosis_vencidas(verbose=False)
    async with engine.begin() as c:
        pend = (await c.execute(text(
            "SELECT count(*) FROM scheduled_doses sd JOIN medications m "
            "ON m.id = sd.medication_id WHERE sd.status IN ('pending','postponed') "
            "AND coalesce(sd.postponed_until, sd.scheduled_at) "
            "    + make_interval(mins => m.grace_window_min) < now()"))).scalar()
        check("no deja nada vencido atras", pend == 0, pend)
        # La segunda corrida solo puede marcar lo que vencio en el intervalo.
        check("es idempotente", r2["marcadas"] == 0, r2)

        await limpiar(c)

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

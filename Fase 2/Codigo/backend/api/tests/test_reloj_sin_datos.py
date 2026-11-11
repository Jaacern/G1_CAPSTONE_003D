"""Pruebas de la alerta de reloj sin datos (RF-44).

Es la alerta que avisa que las otras dejaron de funcionar: sin datos del
reloj no hay alerta de saturacion ni de frecuencia, y el silencio se lee como
que todo esta bien. Lo que mas se cuida aqui es que avise una vez por
silencio y no una vez por hora.
"""
import asyncio, os, sys
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")

import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

from sqlalchemy import text  # noqa: E402
from app.db import engine  # noqa: E402
from app.maintenance import alertar_reloj_sin_datos  # noqa: E402

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

LUIS = "33333333-3333-4333-8333-333333333334"
CUIDADORA = "22222222-2222-4222-8222-222222222222"


async def poner(c, **campos):
    """Ajusta el reloj vigente de Luis. Los valores son expresiones SQL."""
    sets = ", ".join(f"{k} = {v}" for k, v in campos.items())
    await c.execute(text(
        f"UPDATE wearables SET {sets} WHERE patient_id = :p AND unlinked_at IS NULL"),
        {"p": LUIS})


PREVIAS: set[str] = set()


async def alertas(c):
    """Las alertas de reloj sin datos que nacieron durante esta prueba."""
    filas = (await c.execute(text(
        "SELECT id, severity, status, title, detail, dedup_key, payload "
        "FROM alerts WHERE patient_id = :p AND type = 'wearable_offline' "
        "ORDER BY created_at"), {"p": LUIS})).mappings().all()
    return [f for f in filas if str(f["id"]) not in PREVIAS]


async def main():
    async with engine.begin() as c:
        # Foto de todos los relojes, para dejarlos como estaban.
        foto = (await c.execute(text(
            "SELECT id, last_sync_at, created_at, unlinked_at FROM wearables"))).all()
        previas = {str(r[0]) for r in (await c.execute(text(
            "SELECT id FROM alerts WHERE type = 'wearable_offline'"))).all()}
        PREVIAS.update(previas)
        limite = (await c.execute(text(
            "SELECT value FROM system_parameters "
            "WHERE key = 'wearable_offline_minutes'"))).scalar()
        # Todos al dia: la funcion mira a todos los pacientes, y la prueba
        # necesita que el unico callado sea el que ella calla.
        await c.execute(text("UPDATE wearables SET last_sync_at = now() "
                             "WHERE unlinked_at IS NULL"))
        tiene = (await c.execute(text(
            "SELECT count(*) FROM wearables WHERE patient_id = :p "
            "AND unlinked_at IS NULL"), {"p": LUIS})).scalar()
    check("el paciente de prueba tiene un reloj vigente", tiene == 1, tiene)

    try:
        r = await alertar_reloj_sin_datos(verbose=False)
        check("con todos los relojes al dia no avisa", r["creadas"] == 0, r)

        # ---------------- el silencio ----------------
        async with engine.begin() as c:
            await poner(c, last_sync_at="now() - interval '119 minutes'")
        r = await alertar_reloj_sin_datos(verbose=False)
        check("bajo el limite todavia no avisa", r["creadas"] == 0, r)

        async with engine.begin() as c:
            await poner(c, last_sync_at="now() - interval '3 hours'")
        r = await alertar_reloj_sin_datos(verbose=False)
        check("pasado el limite crea la alerta", r["creadas"] == 1, r)
        async with engine.begin() as c:
            a = await alertas(c)
        check("una sola alerta", len(a) == 1, len(a))
        if a:
            check("es un aviso, no una critica, y nace activa",
                  a[0]["severity"] == "warning" and a[0]["status"] == "active",
                  dict(a[0]))
            check("el titulo dice que pasa", a[0]["title"] == "Reloj sin datos",
                  a[0]["title"])
            check("el detalle nombra al paciente y desde cuando",
                  "Luis" in a[0]["detail"] and "no envía datos desde" in a[0]["detail"],
                  a[0]["detail"])
            check("payload apunta al reloj",
                  a[0]["payload"].get("wearable_id")
                  and a[0]["payload"].get("last_sync_at"), a[0]["payload"])

        # ---------------- una por silencio ----------------
        r = await alertar_reloj_sin_datos(verbose=False)
        check("la pasada siguiente no la repite", r["creadas"] == 0, r)

        async with engine.begin() as c:
            await c.execute(text(
                "UPDATE alerts SET status = 'resolved', acknowledged_by = :u, "
                "  acknowledged_at = now(), resolved_by = :u, resolved_at = now() "
                "WHERE id = :a"), {"u": CUIDADORA, "a": a[0]["id"]})
        r = await alertar_reloj_sin_datos(verbose=False)
        check("resuelta la alerta, el mismo silencio no vuelve a avisar",
              r["creadas"] == 0, r)

        # El reloj volvio, sincronizo, y se callo de nuevo. Como no se puede
        # esperar dos horas, se corre la alerta anterior hacia atras.
        async with engine.begin() as c:
            await c.execute(text(
                "UPDATE alerts SET created_at = now() - interval '6 hours', "
                "  acknowledged_at = now() - interval '5 hours 50 minutes', "
                "  resolved_at = now() - interval '5 hours 50 minutes' "
                "WHERE id = :a"), {"a": a[0]["id"]})
            await poner(c, last_sync_at="now() - interval '3 hours'")
        r = await alertar_reloj_sin_datos(verbose=False)
        check("un silencio nuevo, despues de haber sincronizado, avisa otra vez",
              r["creadas"] == 1, r)

        # ---------------- nunca sincronizo ----------------
        async with engine.begin() as c:
            await c.execute(text(
                "UPDATE alerts SET created_at = now() - interval '6 hours' "
                "WHERE patient_id = :p AND type = 'wearable_offline' "
                "  AND created_at > now() - interval '1 hour'"), {"p": LUIS})
            await poner(c, last_sync_at="NULL",
                        created_at="now() - interval '3 hours'")
        r = await alertar_reloj_sin_datos(verbose=False)
        check("un reloj vinculado que nunca envio nada tambien avisa",
              r["creadas"] == 1, r)
        async with engine.begin() as c:
            a = await alertas(c)
        check("y lo dice asi, no inventa una ultima sincronizacion",
              a and "todavía no ha enviado datos" in a[-1]["detail"]
              and a[-1]["payload"].get("last_sync_at") is None,
              dict(a[-1]) if a else None)

        # ---------------- el parametro manda ----------------
        async with engine.begin() as c:
            await c.execute(text(
                "UPDATE alerts SET created_at = now() - interval '6 hours' "
                "WHERE patient_id = :p AND type = 'wearable_offline' "
                "  AND created_at > now() - interval '1 hour'"), {"p": LUIS})
            await poner(c, last_sync_at="now() - interval '90 minutes'")
            await c.execute(text("UPDATE system_parameters SET value = '60' "
                                 "WHERE key = 'wearable_offline_minutes'"))
        r = await alertar_reloj_sin_datos(verbose=False)
        check("respeta wearable_offline_minutes", r["creadas"] == 1, r)
        async with engine.begin() as c:
            await c.execute(text("UPDATE system_parameters SET value = :v "
                                 "WHERE key = 'wearable_offline_minutes'"),
                            {"v": limite})

        # ---------------- un reloj desvinculado ----------------
        async with engine.begin() as c:
            await c.execute(text(
                "UPDATE alerts SET created_at = now() - interval '6 hours' "
                "WHERE patient_id = :p AND type = 'wearable_offline' "
                "  AND created_at > now() - interval '1 hour'"), {"p": LUIS})
            await poner(c, last_sync_at="now() - interval '3 hours'",
                        unlinked_at="now()")
        r = await alertar_reloj_sin_datos(verbose=False)
        check("un reloj desvinculado no avisa", r["creadas"] == 0, r)
    finally:
        async with engine.begin() as c:
            await c.execute(text(
                "UPDATE system_parameters SET value = :v "
                "WHERE key = 'wearable_offline_minutes'"), {"v": limite})
            await c.execute(text(
                "DELETE FROM alert_deliveries WHERE alert_id IN (SELECT id "
                "  FROM alerts WHERE type = 'wearable_offline' "
                "  AND NOT (CAST(id AS text) = ANY(:previas)))"),
                {"previas": list(previas)})
            await c.execute(text(
                "DELETE FROM alerts WHERE type = 'wearable_offline' "
                "AND NOT (CAST(id AS text) = ANY(:previas))"),
                {"previas": list(previas)})
            # Primero se sueltan todos y despues se reponen, para no chocar
            # con el indice de un solo reloj vigente por paciente.
            for r in foto:
                await c.execute(text(
                    "UPDATE wearables SET last_sync_at = :s, created_at = :c, "
                    "  unlinked_at = :u WHERE id = :i"),
                    {"s": r[1], "c": r[2], "u": r[3], "i": r[0]})

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

"""Pruebas del calculo del semaforo.

La prueba importante es la ultima: compara el resultado del proceso
contra _compute_wellbeing del propio router, no contra una copia. Si
alguien cambia la regla en vitals.py y no aca, esta prueba se cae, que
es justo lo que tiene que pasar.
"""
import asyncio, json, os, sys
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
from app.db import engine, SessionLocal
from app.maintenance import calcular_semaforo, ZONA
from app.routers.vitals import (_compute_wellbeing, _active_alerts,
                                _latest_items, _medications_today)

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

PAC = "33333333-3333-4333-8333-333333333333"
MED = "77777777-7777-4777-8777-777777777777"

async def borrar_alertas(c):
    # Primero los avisos de esas alertas. Desde que las alertas se reparten al
    # telefono, una alerta puede tener entregas colgando (alert_deliveries la
    # referencia con RESTRICT) y borrarla directo falla.
    await c.execute(text(
        "DELETE FROM alert_deliveries WHERE alert_id IN "
        "(SELECT id FROM alerts WHERE title = 'FIXTURE')"))
    await c.execute(text("DELETE FROM alerts WHERE title = 'FIXTURE'"))


async def limpiar(c):
    await borrar_alertas(c)
    await c.execute(text(
        "DELETE FROM vital_readings WHERE meta ->> 'origin' = 'FIXTURE'"))
    await c.execute(text("DELETE FROM scheduled_doses WHERE reason = 'FIXTURE'"))

async def foto(c):
    return (await c.execute(text(
        "SELECT status, reasons, vitals_out_of_range, doses_missed, "
        "  active_alerts, snapshot_date, computed_at FROM wellbeing_snapshots "
        "WHERE patient_id = :p AND snapshot_date = "
        "  CAST(now() AT TIME ZONE :z AS date)"),
        {"p": PAC, "z": ZONA})).mappings().first()

async def alerta(c, severidad):
    await c.execute(text(
        "INSERT INTO alerts (patient_id, type, severity, title, status) "
        "VALUES (:p, 'fall', :s, 'FIXTURE', 'active')"),
        {"p": PAC, "s": severidad})

async def main():
    async with engine.begin() as c:
        await limpiar(c)
        # Se parte de un paciente sin nada: ni alertas activas, ni
        # mediciones fuera de rango, ni dosis omitidas hoy.
        await c.execute(text(
            "UPDATE alerts SET status = 'resolved', "
            "  acknowledged_by = coalesce(acknowledged_by, :u), "
            "  acknowledged_at = coalesce(acknowledged_at, now()), "
            "  resolved_by = coalesce(resolved_by, :u), "
            "  resolved_at = coalesce(resolved_at, now()) "
            "WHERE patient_id = :p AND status <> 'resolved'"),
            {"p": PAC, "u": "22222222-2222-4222-8222-222222222222"})
        await c.execute(text(
            "UPDATE scheduled_doses sd SET status = 'pending', logged_by = NULL, "
            "  logged_at = NULL, administered_at = NULL, reason = NULL "
            "FROM medications m WHERE m.id = sd.medication_id "
            "  AND m.patient_id = :p AND sd.status = 'missed' "
            "  AND CAST(sd.scheduled_at AT TIME ZONE :z AS date) "
            "      = CAST(now() AT TIME ZONE :z AS date)"), {"p": PAC, "z": ZONA})
        # Una medicion en rango, la mas nueva de cada tipo con umbral.
        for t, v in (("spo2", 97), ("heart_rate", 72)):
            await c.execute(text(
                "INSERT INTO vital_readings (patient_id, type, value, "
                "  measured_at, source, meta) VALUES (:p, :t, :v, now(), "
                "  'manual', '{\"origin\":\"FIXTURE\"}'::jsonb)"),
                {"p": PAC, "t": t, "v": v})

    r = await calcular_semaforo(verbose=False)
    check("calcula todos los pacientes vivos", r["pacientes"] >= 1, r)
    async with engine.begin() as c:
        f = await foto(c)
        check("guarda la fotografia del dia", f is not None)
        check("sin motivos queda en ok", f and f["status"] == "ok", dict(f) if f else None)
        check("sin motivos la lista va vacia", f and f["reasons"] == [], f["reasons"] if f else None)
        check("los conteos quedan en cero",
              f and f["vitals_out_of_range"] == 0 and f["doses_missed"] == 0
              and f["active_alerts"] == 0, dict(f) if f else None)

        # Una alerta warning activa: amarillo.
        await alerta(c, "warning")
    await calcular_semaforo(verbose=False)
    async with engine.begin() as c:
        f = await foto(c)
        check("una alerta de aviso lo pone en warning", f["status"] == "warning",
              dict(f))
        check("el motivo nombra la alerta",
              "Alerta activa: FIXTURE" in f["reasons"], f["reasons"])
        check("cuenta la alerta activa", f["active_alerts"] == 1, dict(f))

        # Una critica manda a rojo por encima del amarillo.
        await alerta(c, "critical")
    await calcular_semaforo(verbose=False)
    async with engine.begin() as c:
        f = await foto(c)
        check("una alerta critica lo pone en attention", f["status"] == "attention",
              dict(f))
        check("la critica va primero en los motivos",
              f["reasons"][0] == "Alerta crítica activa: FIXTURE", f["reasons"])

        # Se limpian las alertas y se deja un vital fuera de rango.
        await borrar_alertas(c)
        await c.execute(text(
            "INSERT INTO vital_readings (patient_id, type, value, measured_at, "
            "  source, meta) VALUES (:p, 'spo2', 88, now(), 'manual', "
            "  '{\"origin\":\"FIXTURE\"}'::jsonb)"), {"p": PAC})
    await calcular_semaforo(verbose=False)
    async with engine.begin() as c:
        f = await foto(c)
        check("un vital fuera de rango lo pone en attention",
              f["status"] == "attention", dict(f))
        check("cuenta el vital fuera de rango", f["vitals_out_of_range"] == 1,
              dict(f))
        check("el motivo del vital usa el formato del router",
              any(m.startswith("spo2 fuera de rango (88.0 ") for m in f["reasons"]),
              f["reasons"])

        # Se normaliza y se deja una dosis omitida hoy.
        await c.execute(text(
            "INSERT INTO vital_readings (patient_id, type, value, measured_at, "
            "  source, meta) VALUES (:p, 'spo2', 98, now(), 'manual', "
            "  '{\"origin\":\"FIXTURE\"}'::jsonb)"), {"p": PAC})
        # La hora se ancla al dia LOCAL y no a "hace tres horas". Con
        # now() - 3 horas la dosis cae en el dia anterior cada vez que la
        # prueba corre entre medianoche y las tres de la madrugada de Chile,
        # y el semaforo cuenta por dia local: la prueba fallaba por la hora
        # a la que se corria, no por el codigo.
        #
        # 03:17 y no una hora redonda porque scheduled_doses tiene unico
        # (medication_id, scheduled_at) y las horas en punto son justo las
        # que ocupan las dosis de verdad.
        await c.execute(text(
            "INSERT INTO scheduled_doses (medication_id, scheduled_at, status, "
            "  reason) VALUES (:m, "
            "  (CAST(now() AT TIME ZONE CAST(:z AS text) AS date) "
            "     + time '03:17') AT TIME ZONE CAST(:z AS text), "
            "  'missed', 'FIXTURE')"), {"m": MED, "z": ZONA})
    await calcular_semaforo(verbose=False)
    async with engine.begin() as c:
        f = await foto(c)
        check("una dosis omitida hoy lo pone en warning", f["status"] == "warning",
              dict(f))
        check("cuenta la dosis omitida", f["doses_missed"] == 1, dict(f))
        check("el motivo de la dosis usa el formato del router",
              "1 dosis omitida(s) hoy" in f["reasons"], f["reasons"])

        antes = f["computed_at"]
    # Idempotencia: una fila por dia, se actualiza y no se duplica.
    await calcular_semaforo(verbose=False)
    async with engine.begin() as c:
        n = (await c.execute(text(
            "SELECT count(*) FROM wellbeing_snapshots WHERE patient_id = :p "
            "AND snapshot_date = CAST(now() AT TIME ZONE :z AS date)"),
            {"p": PAC, "z": ZONA})).scalar()
        check("una sola fila por paciente y dia", n == 1, n)
        f = await foto(c)
        check("recalcular refresca computed_at", f["computed_at"] >= antes)

    # --- La prueba que importa: contra la funcion del router ---
    async with SessionLocal() as db:
        alertas = await _active_alerts(db, PAC)
        vitales = await _latest_items(db, PAC)
        meds    = await _medications_today(db, PAC)
        esperado, motivos_router = _compute_wellbeing(alertas, vitales, meds)

    async with engine.begin() as c:
        f = await foto(c)
        check("el estado coincide con _compute_wellbeing del router",
              f["status"] == esperado, (f["status"], esperado))
        check("los motivos coinciden palabra por palabra con el router",
              f["reasons"] == motivos_router,
              (f["reasons"], motivos_router))
        await limpiar(c)

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

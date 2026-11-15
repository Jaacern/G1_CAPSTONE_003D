"""Pruebas de la alerta por medicion fuera de rango."""
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
from app.maintenance import alertar_vitales_fuera_de_rango, _numero

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

PAC = "33333333-3333-4333-8333-333333333333"

async def limpiar(c):
    # Primero los avisos de esas alertas. Desde que las alertas se reparten al
    # telefono, una alerta puede tener entregas colgando (alert_deliveries la
    # referencia con RESTRICT) y borrarla directo falla.
    await c.execute(text(
        "DELETE FROM alert_deliveries WHERE alert_id IN ("
        "  SELECT id FROM alerts WHERE payload ->> 'reading_id' IN "
        "  (SELECT CAST(id AS text) FROM vital_readings "
        "    WHERE meta ->> 'origin' = 'FIXTURE'))"))
    await c.execute(text(
        "DELETE FROM alerts WHERE payload ->> 'reading_id' IN "
        "(SELECT CAST(id AS text) FROM vital_readings "
        "  WHERE meta ->> 'origin' = 'FIXTURE')"))
    await c.execute(text(
        "DELETE FROM vital_readings WHERE meta ->> 'origin' = 'FIXTURE'"))

async def medir(c, tipo, valor, minutos=0):
    """Deja una medicion que es, con seguridad, la ULTIMA de su tipo.

    El motor solo mira la ultima medicion de cada tipo. El seed deja
    mediciones del wearable hasta el momento en que se creo la base, asi
    que una medicion de prueba fechada "hace un minuto" quedaba por detras
    del seed si la prueba corria durante el primer minuto de vida de la
    base, y entonces no alertaba nada. Fallaba segun cuanto hubiera tardado
    el esquema en aplicarse, que es lo peor que puede depender una prueba.

    Con minutos > 0 se pide a proposito una medicion vieja, y ahi la fecha
    manda: es justo lo que esa comprobacion quiere probar.
    """
    # Los CAST explicitos son para asyncpg: el mismo parametro aparece en el
    # INSERT y en la subconsulta, y sin ellos no logra deducir el tipo.
    if minutos:
        cuando = "now() - make_interval(mins => :m)"
    else:
        cuando = ("greatest(now(), coalesce((SELECT max(measured_at) "
                  "  FROM vital_readings "
                  "  WHERE patient_id = CAST(:p AS uuid) "
                  "    AND type = CAST(:t AS varchar)), "
                  "  now()) + interval '1 second')")
    return str((await c.execute(text(
        "INSERT INTO vital_readings (patient_id, type, value, measured_at, "
        f"  source, meta) VALUES (CAST(:p AS uuid), CAST(:t AS varchar), :v, "
        f"  {cuando}, 'manual', "
        "  '{\"origin\":\"FIXTURE\"}'::jsonb) RETURNING id"),
        {"p": PAC, "t": tipo, "v": valor, "m": minutos})).scalar())

async def alerta_de(c, rid):
    return (await c.execute(text(
        "SELECT type, severity, title, detail, dedup_key, status, payload "
        "FROM alerts WHERE payload ->> 'reading_id' = :i"),
        {"i": rid})).mappings().all()

async def main():
    async with engine.begin() as c:
        await limpiar(c)
        th = (await c.execute(text(
            "SELECT type, min_value, max_value FROM vital_thresholds "
            "WHERE patient_id = :p ORDER BY type"), {"p": PAC})).mappings().all()
        check("el paciente tiene umbrales", len(th) >= 2, [dict(t) for t in th])
        # heart_rate 50-110, spo2 min 92.
        await c.execute(text("UPDATE system_parameters SET value = '0' "
                             "WHERE key = 'alert_dedup_minutes'"))
    # Se drena lo que ya pudiera estar fuera de rango en la base.
    await alertar_vitales_fuera_de_rango(verbose=False)

    async with engine.begin() as c:
        baja   = await medir(c, "spo2", 89)
        alta   = await medir(c, "heart_rate", 128)
    r = await alertar_vitales_fuera_de_rango(verbose=False)
    check("crea una alerta por medicion fuera de rango", r["creadas"] == 2, r)

    async with engine.begin() as c:
        a = await alerta_de(c, baja)
        check("una sola alerta para esa medicion", len(a) == 1, len(a))
        if a:
            a = a[0]
            check("tipo y severidad", a["type"] == "vital_out_of_range"
                  and a["severity"] == "warning", dict(a))
            check("nace activa", a["status"] == "active", a["status"])
            check("titulo dice que va bajo el minimo",
                  a["title"] == "Saturación O₂ bajo el mínimo", a["title"])
            check("detalle con valor y limite configurado",
                  a["detail"] == "Saturación O₂ 89 % (mínimo configurado 92 %).",
                  a["detail"])
            check("dedup_key sale del codigo del catalogo",
                  a["dedup_key"] == "spo2_low", a["dedup_key"])
            check("payload guarda la medicion y el umbral",
                  a["payload"]["value"] == 89.0
                  and a["payload"]["min_value"] == 92.0, a["payload"])
        b = await alerta_de(c, alta)
        if b:
            check("titulo dice que va sobre el maximo",
                  b[0]["title"] == "Frecuencia cardíaca sobre el máximo",
                  b[0]["title"])
            check("dedup_key del maximo", b[0]["dedup_key"] == "heart_rate_high",
                  b[0]["dedup_key"])

    # Idempotencia.
    r2 = await alertar_vitales_fuera_de_rango(verbose=False)
    check("es idempotente", r2["creadas"] == 0, r2)

    async with engine.begin() as c:
        # Dentro de rango: nada.
        dentro = await medir(c, "spo2", 95)
        # Justo en el borde: dentro, igual que _in_range de la pantalla.
        borde  = await medir(c, "heart_rate", 110)
    r3 = await alertar_vitales_fuera_de_rango(verbose=False)
    async with engine.begin() as c:
        check("no alerta un valor en rango", len(await alerta_de(c, dentro)) == 0)
        check("el valor justo en el borde esta dentro",
              len(await alerta_de(c, borde)) == 0, r3)

        # Una medicion vieja no alerta.
        vieja = await medir(c, "spo2", 80, minutos=60 * 24)
    r4 = await alertar_vitales_fuera_de_rango(verbose=False)
    async with engine.begin() as c:
        check("no alerta una medicion vieja",
              len(await alerta_de(c, vieja)) == 0, r4)

        # Solo la ultima de cada tipo: una fuera de rango tapada por otra
        # mas nueva en rango no alerta.
        tapada = await medir(c, "spo2", 85, minutos=20)
        await medir(c, "spo2", 96, minutos=2)
    r5 = await alertar_vitales_fuera_de_rango(verbose=False)
    async with engine.begin() as c:
        check("solo mira la ultima medicion de cada tipo",
              len(await alerta_de(c, tapada)) == 0, r5)

        # Un tipo sin umbral configurado no alerta nunca. La semilla puede
        # traer umbral de glucosa: se da de baja mientras dura este caso y
        # se restaura despues, para no depender de los datos de prueba.
        baja_glucosa = [str(x) for x in (await c.execute(text(
            "UPDATE vital_thresholds SET deleted_at = now() "
            "WHERE patient_id = :p AND type = 'glucose' AND deleted_at IS NULL "
            "RETURNING id"), {"p": PAC})).scalars().all()]
        sin_umbral = await medir(c, "glucose", 400)
    r6 = await alertar_vitales_fuera_de_rango(verbose=False)
    async with engine.begin() as c:
        check("un tipo sin umbral no alerta",
              len(await alerta_de(c, sin_umbral)) == 0, r6)
        # La medicion de prueba se va antes de devolver el umbral: si no,
        # vuelve a contar en las corridas siguientes de este mismo test.
        await c.execute(text("DELETE FROM vital_readings WHERE id = :i"),
                        {"i": sin_umbral})
        for tid in baja_glucosa:
            await c.execute(text("UPDATE vital_thresholds SET deleted_at = NULL "
                                 "WHERE id = :i"), {"i": tid})

        # La ventana frena, pero no descarta.
        await c.execute(text("UPDATE system_parameters SET value = '30' "
                             "WHERE key = 'alert_dedup_minutes'"))
        otra = await medir(c, "spo2", 88)
    r7 = await alertar_vitales_fuera_de_rango(verbose=False)
    check("la ventana frena el aviso",
          r7["creadas"] == 0 and r7["en_espera"] >= 1, r7)
    async with engine.begin() as c:
        await c.execute(text("UPDATE alerts SET created_at = now() - interval "
                             "'2 hours' WHERE dedup_key LIKE 'spo2%'"))
    r8 = await alertar_vitales_fuera_de_rango(verbose=False)
    async with engine.begin() as c:
        check("pasada la ventana lo crea, no lo descarta",
              len(await alerta_de(c, otra)) == 1, r8)

        # Un umbral dado de baja no alerta.
        await c.execute(text("UPDATE system_parameters SET value = '0' "
                             "WHERE key = 'alert_dedup_minutes'"))
        await c.execute(text("UPDATE vital_thresholds SET deleted_at = now() "
                             "WHERE patient_id = :p AND type = 'spo2'"),
                        {"p": PAC})
        tras_baja = await medir(c, "spo2", 70)
    r9 = await alertar_vitales_fuera_de_rango(verbose=False)
    async with engine.begin() as c:
        check("un umbral dado de baja no alerta",
              len(await alerta_de(c, tras_baja)) == 0, r9)
        await c.execute(text("UPDATE vital_thresholds SET deleted_at = NULL "
                             "WHERE patient_id = :p"), {"p": PAC})
        await c.execute(text("UPDATE system_parameters SET value = '30' "
                             "WHERE key = 'alert_dedup_minutes'"))
        await limpiar(c)

    check("numeros sin decimales de maquina", _numero(89.00) == "89"
          and _numero(90.5) == "90.5", (_numero(89.00), _numero(90.5)))

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

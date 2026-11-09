"""Pruebas del umbral dado de baja, sobre los ayudantes del router.

deleted_at existe para dejar de aplicar un umbral sin perder el registro
de que estuvo. _load_thresholds_map no lo filtraba, asi que un umbral de
baja seguia pintando el valor en rojo.

La prueba trabaja sobre 'glucose', que el seed no configura: asi crea y
destruye su propio umbral y no deja tocados los del paciente, ni siquiera
si se cae a la mitad.
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
from app.db import engine, SessionLocal
from app.routers.vitals import _load_thresholds_map, _latest_items

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

PAC = "33333333-3333-4333-8333-333333333333"
FAM = "11111111-1111-4111-8111-111111111111"
TIPO = "glucose"

async def limpiar(c):
    await c.execute(text(
        "DELETE FROM vital_readings WHERE meta ->> 'origin' = 'FIXTURE-BAJA'"))
    await c.execute(text(
        "DELETE FROM vital_thresholds WHERE patient_id = :p AND type = :t"),
        {"p": PAC, "t": TIPO})

async def vital(db):
    return {v.type: v for v in await _latest_items(db, PAC)}

async def main():
    async with engine.begin() as c:
        await limpiar(c)
        await c.execute(text(
            "INSERT INTO vital_thresholds (patient_id, type, min_value, "
            "  max_value, updated_by) VALUES (:p, :t, 70, 180, :u)"),
            {"p": PAC, "t": TIPO, "u": FAM})
        # 250 mg/dL con maximo 180: fuera de rango.
        await c.execute(text(
            "INSERT INTO vital_readings (patient_id, type, value, measured_at, "
            "  source, meta) VALUES (:p, :t, 250, now(), 'manual', "
            "  '{\"origin\":\"FIXTURE-BAJA\"}'::jsonb)"), {"p": PAC, "t": TIPO})

    async with SessionLocal() as db:
        check("el umbral vigente se carga", TIPO in await _load_thresholds_map(db, PAC))
        check("con umbral vigente, 250 sale fuera de rango",
              (await vital(db))[TIPO].in_range is False)

    async with engine.begin() as c:
        await c.execute(text(
            "UPDATE vital_thresholds SET deleted_at = now() "
            "WHERE patient_id = :p AND type = :t"), {"p": PAC, "t": TIPO})

    async with SessionLocal() as db:
        umbrales = await _load_thresholds_map(db, PAC)
        check("el umbral de baja no se carga", TIPO not in umbrales, list(umbrales))
        check("sin umbral vigente, 250 deja de salir en rojo",
              (await vital(db))[TIPO].in_range is True)
        # Y no debe tapar los que si estan vigentes.
        check("no afecta a los umbrales vigentes del paciente",
              "heart_rate" in umbrales, list(umbrales))

    async with engine.begin() as c:
        listados = (await c.execute(text(
            "SELECT type FROM vital_thresholds WHERE patient_id = :p "
            "  AND deleted_at IS NULL"), {"p": PAC})).scalars().all()
        check("el listado omite el umbral de baja", TIPO not in listados,
              list(listados))

        # Volver a fijarlo: con el indice parcial la fila de baja no entra
        # en conflicto, asi que se inserta una vigente nueva y la anterior
        # queda como historia. El WHERE es obligatorio para que el
        # ON CONFLICT infiera el indice.
        await c.execute(text(
            """
            INSERT INTO vital_thresholds
                (patient_id, type, min_value, max_value, updated_by)
            VALUES (:p, :t, 70, 180, :u)
            ON CONFLICT (patient_id, type) WHERE deleted_at IS NULL
            DO UPDATE SET min_value = EXCLUDED.min_value,
                          max_value = EXCLUDED.max_value,
                          updated_by = EXCLUDED.updated_by,
                          updated_at = now()
            """), {"p": PAC, "t": TIPO, "u": FAM})

    async with SessionLocal() as db:
        check("volver a fijarlo lo revive", TIPO in await _load_thresholds_map(db, PAC))
        check("y vuelve a marcar el 250 fuera de rango",
              (await vital(db))[TIPO].in_range is False)

    async with engine.begin() as c:
        vig, baja = (await c.execute(text(
            "SELECT count(*) FILTER (WHERE deleted_at IS NULL), "
            "       count(*) FILTER (WHERE deleted_at IS NOT NULL) "
            "FROM vital_thresholds WHERE patient_id = :p AND type = :t"),
            {"p": PAC, "t": TIPO})).first()
        check("queda uno vigente y el de baja como historia",
              (vig, baja) == (1, 1), (vig, baja))
        await limpiar(c)
        quedan = (await c.execute(text(
            "SELECT count(*) FROM vital_thresholds WHERE patient_id = :p"),
            {"p": PAC})).scalar()
        check("la prueba no deja nada suyo atras", quedan == 2, quedan)

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

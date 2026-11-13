"""Pruebas de que las tomas futuras dejan de aparecer al cambiar el plan.

RF-26 y RF-27. Las tomas se generan con dias de anticipacion, asi que cuando
el medico descontinua un medicamento o cambia sus horarios, las ya generadas
no desaparecen solas. Al adulto mayor le seguian apareciendo las tomas de un
remedio que ya no toma, el barrido horario las pasaba a 'missed' por no
confirmarlas, y la adherencia le bajaba a una persona que hizo todo bien.

Lo que mas se cuida aqui no es que se cancelen, sino que se cancele SOLO lo
que corresponde: lo ya administrado no se reescribe, lo de hoy que ya paso
tampoco, y el otro paciente no se entera.
"""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")

import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

import asyncio  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.maintenance import generar_dosis, marcar_dosis_vencidas  # noqa: E402
from app.routers import medications, treatments  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(medications.router)
app.include_router(treatments.router)

ELENA    = "33333333-3333-4333-8333-333333333333"
LUIS     = "33333333-3333-4333-8333-333333333334"
MARCA    = "PRUEBA-CANCELAR"

n = ok = 0


def check(nombre, cond, detalle=""):
    global n, ok
    n += 1
    if cond:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}   {detalle}")


def token(uid: str) -> dict:
    cfg = get_settings()
    t = jwt.encode(
        {"sub": uid, "type": "access",
         "exp": int((datetime.now(timezone.utc) + timedelta(minutes=15)).timestamp())},
        cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


async def sql(q, **p):
    async with engine.begin() as c:
        return await c.execute(text(q), p)


async def estados(**filtro) -> dict[str, int]:
    """Cuenta por estado las tomas que cumplen el filtro."""
    where, params = [], {}
    if "medication_id" in filtro:
        where.append("sd.medication_id = CAST(:m AS uuid)")
        params["m"] = filtro["medication_id"]
    if "treatment_id" in filtro:
        where.append("sd.treatment_item_id IN (SELECT id FROM treatment_items "
                     "WHERE treatment_id = CAST(:t AS uuid))")
        params["t"] = filtro["treatment_id"]
    if filtro.get("futuras"):
        where.append("sd.scheduled_at > now()")
    filas = (await sql(
        f"SELECT sd.status, count(*) AS n FROM scheduled_doses sd "
        f"WHERE {' AND '.join(where)} GROUP BY 1", **params)).all()
    return {r[0]: r[1] for r in filas}


async def limpiar():
    await sql("DELETE FROM scheduled_doses WHERE medication_id IN "
              "(SELECT id FROM medications WHERE name LIKE :m)", m=MARCA + "%")
    await sql("DELETE FROM medication_times WHERE medication_id IN "
              "(SELECT id FROM medications WHERE name LIKE :m)", m=MARCA + "%")
    await sql("DELETE FROM medication_days WHERE medication_id IN "
              "(SELECT id FROM medications WHERE name LIKE :m)", m=MARCA + "%")
    await sql("DELETE FROM medications WHERE name LIKE :m", m=MARCA + "%")


async def main(client):
    # El id del medico no se escribe a mano: el sembrado de demostracion lo
    # genera al azar, asi que en cada base es otro. Se busca el medico
    # habilitado del paciente, que es quien puede cambiar su plan.
    medico = (await sql(
        "SELECT u.id FROM patient_members pm "
        "JOIN users u ON u.id = pm.user_id "
        "JOIN doctor_profiles d ON d.user_id = u.id AND d.revoked_at IS NULL "
        "WHERE pm.patient_id = :p AND pm.role = 'doctor' "
        "  AND pm.removed_at IS NULL LIMIT 1", p=ELENA)).scalar()
    check("el paciente tiene un medico habilitado", medico is not None)
    if medico is None:
        return
    medico = str(medico)
    h = token(medico)
    await limpiar()

    # ---------------- el modelo de tratamientos ----------------
    # Es el que corre hoy: el generador ignora medications en cuanto el
    # paciente tiene un tratamiento vigente.
    print("--- al reemplazar un tratamiento ---")
    viejo = (await sql(
        "SELECT id FROM treatments WHERE patient_id = :p AND status = 'vigente' "
        "ORDER BY effective_from DESC LIMIT 1", p=ELENA)).scalar()
    check("el paciente tiene un tratamiento vigente", viejo is not None)
    await generar_dosis(dias=14, verbose=False)
    antes = await estados(treatment_id=str(viejo), futuras=True)
    check("y tomas futuras generadas", antes.get("pending", 0) > 0, antes)

    # Una toma del pasado ya registrada, que no se puede tocar.
    administrada = (await sql(
        "SELECT sd.id FROM scheduled_doses sd JOIN treatment_items ti "
        "  ON ti.id = sd.treatment_item_id "
        "WHERE ti.treatment_id = CAST(:t AS uuid) AND sd.scheduled_at < now() "
        "ORDER BY sd.scheduled_at DESC LIMIT 1", t=str(viejo))).scalar()
    if administrada:
        # logged_at va junto con logged_by: ck_scheduled_doses_logged_pair
        # exige que esten los dos o ninguno. Sin el, esto pasaba o fallaba
        # segun que toma eligiera la consulta.
        await sql("UPDATE scheduled_doses SET status = 'taken', "
                  "  administered_at = scheduled_at, "
                  "  logged_at = scheduled_at, logged_by = :u "
                  "WHERE id = :i", i=administrada, u=medico)

    items = (await sql(
        "SELECT ti.name, ti.dose_amount, ti.dose_unit FROM treatment_items ti "
        "WHERE ti.treatment_id = CAST(:t AS uuid) AND NOT ti.is_prn "
        "  AND ti.action <> 'removed' LIMIT 1", t=str(viejo))).mappings().first()
    check("tiene al menos una indicacion con horario", items is not None)

    r = await client.post(
        f"/api/v1/patients/{ELENA}/treatments", headers=h,
        json={"note": MARCA, "items": [{
            "name": items["name"], "dose_amount": float(items["dose_amount"]),
            "dose_unit": items["dose_unit"], "times": ["07:45"],
        }]})
    check("el medico prescribe un tratamiento nuevo", r.status_code == 201,
          f"{r.status_code} {r.text[:150]}")

    despues = await estados(treatment_id=str(viejo), futuras=True)
    check("las tomas futuras del tratamiento anterior quedan canceladas",
          despues.get("pending", 0) == 0
          and despues.get("cancelled", 0) == antes.get("pending", 0),
          (antes, despues))
    if administrada:
        est = (await sql("SELECT status FROM scheduled_doses WHERE id = :i",
                         i=administrada)).scalar()
        check("lo ya administrado no se toca", est == "taken", est)
    pasadas = (await sql(
        "SELECT count(*) FROM scheduled_doses sd JOIN treatment_items ti "
        "  ON ti.id = sd.treatment_item_id WHERE ti.treatment_id = CAST(:t AS uuid) "
        "  AND sd.scheduled_at < now() AND sd.status = 'cancelled'",
        t=str(viejo))).scalar()
    check("ninguna toma del pasado se cancelo", pasadas == 0, pasadas)

    otro = await estados(treatment_id=str((await sql(
        "SELECT id FROM treatments WHERE patient_id = :p AND status = 'vigente' "
        "LIMIT 1", p=LUIS)).scalar() or viejo), futuras=True)
    check("el otro paciente no se entera", otro.get("cancelled", 0) == 0, otro)

    nuevo = (await sql(
        "SELECT id FROM treatments WHERE patient_id = :p AND status = 'vigente' "
        "ORDER BY effective_from DESC LIMIT 1", p=ELENA)).scalar()
    await generar_dosis(dias=14, verbose=False)
    n_nuevo = await estados(treatment_id=str(nuevo), futuras=True)
    check("el tratamiento nuevo si genera sus tomas",
          n_nuevo.get("pending", 0) > 0, n_nuevo)
    horas = (await sql(
        "SELECT DISTINCT to_char(sd.scheduled_at AT TIME ZONE :z, 'HH24:MI') "
        "FROM scheduled_doses sd JOIN treatment_items ti ON ti.id = sd.treatment_item_id "
        "WHERE ti.treatment_id = CAST(:t AS uuid) AND sd.status = 'pending' "
        "  AND sd.scheduled_at > now()",
        t=str(nuevo), z=get_settings().timezone)).scalars().all()
    check("y en el horario nuevo", list(horas) == ["07:45"], list(horas))

    # ---------------- el barrido no las toca ----------------
    print("--- una cancelada no se vuelve omitida ---")
    una = (await sql(
        "SELECT sd.id FROM scheduled_doses sd JOIN treatment_items ti "
        "  ON ti.id = sd.treatment_item_id WHERE ti.treatment_id = CAST(:t AS uuid) "
        "  AND sd.status = 'cancelled' LIMIT 1", t=str(viejo))).scalar()
    check("hay una cancelada para probar", una is not None)
    if una is not None:
        await sql("UPDATE scheduled_doses SET scheduled_at = now() - interval '5 hours' "
                  "WHERE id = :i", i=una)
        await marcar_dosis_vencidas(verbose=False)
        est = (await sql("SELECT status FROM scheduled_doses WHERE id = :i",
                         i=una)).scalar()
        check("sigue cancelada, no omitida", est == "cancelled", est)

    # ---------------- no cuenta en la adherencia ni en el dia ----------------
    print("--- no cuenta como falta ---")
    hoy = (await sql("SELECT CAST(now() AT TIME ZONE :z AS date)",
                     z=get_settings().timezone)).scalar()
    futura = (await sql(
        "SELECT sd.id FROM scheduled_doses sd JOIN treatment_items ti "
        "  ON ti.id = sd.treatment_item_id WHERE ti.treatment_id = CAST(:t AS uuid) "
        "  AND sd.status = 'cancelled' AND sd.id <> CAST(:u AS uuid) LIMIT 1",
        t=str(viejo), u=str(una or "00000000-0000-0000-0000-000000000000"))).scalar()
    if futura:
        await sql("UPDATE scheduled_doses SET scheduled_at = "
                  "  (CAST(:d AS date) + time '13:00') AT TIME ZONE :z WHERE id = :i",
                  i=futura, d=hoy, z=get_settings().timezone)
        r = await client.get(f"/api/v1/patients/{ELENA}/doses",
                             params={"date": hoy.isoformat()}, headers=h)
        ids = [d["dose_id"] for d in r.json().get("items", [])]
        check("una cancelada no sale en las dosis del dia",
              r.status_code == 200 and str(futura) not in ids,
              (r.status_code, len(ids)))
        r = await client.get(f"/api/v1/patients/{ELENA}/adherence",
                             params={"date_from": hoy.isoformat(),
                                     "date_to": hoy.isoformat()}, headers=h)
        d = r.json()
        # El dia de la adherencia tiene que cuadrar exactamente con las tomas
        # que la pantalla muestra: si la cancelada contara en alguna columna,
        # sobraria una.
        dia = next((x for x in d.get("daily", []) if x["date"] == hoy.isoformat()),
                   None)
        check("ni cuenta en la adherencia",
              r.status_code == 200 and dia is not None
              and dia["taken"] + dia["missed"] + dia["pending"] == len(ids),
              (dia, len(ids)))

    # ---------------- el modelo antiguo de medicamentos ----------------
    # Sigue vivo para un paciente sin tratamientos. Se cierran los suyos un
    # momento para poder probarlo por la misma puerta que usaria el medico.
    print("--- al descontinuar un medicamento ---")
    vigentes = [r[0] for r in (await sql(
        "SELECT id FROM treatments WHERE patient_id = :p AND status = 'vigente'",
        p=ELENA)).all()]
    # effective_to va junto: un tratamiento cerrado sin fecha de cierre no lo
    # admite la base (ck_treatments_cerrado_fechado).
    await sql("UPDATE treatments SET status = 'superseded', effective_to = now() "
              "WHERE id = ANY(CAST(:i AS uuid[]))", i=[str(x) for x in vigentes])
    try:
        manana = (datetime.now(timezone.utc) + timedelta(days=1)).date()
        r = await client.post(
            f"/api/v1/patients/{ELENA}/medications", headers=h,
            json={"name": f"{MARCA} Enalapril", "dose_amount": 10,
                  "dose_unit": "mg", "times": ["09:00", "21:00"],
                  "start_date": (manana - timedelta(days=1)).isoformat()})
        check("el medico agrega un medicamento", r.status_code == 201,
              f"{r.status_code} {r.text[:150]}")
        mid = r.json()["medication_id"] if r.status_code == 201 else None
        if mid:
            await generar_dosis(dias=14, verbose=False)
            antes = await estados(medication_id=mid, futuras=True)
            check("se le generan tomas", antes.get("pending", 0) > 0, antes)

            r = await client.delete(
                f"/api/v1/patients/{ELENA}/medications/{mid}", headers=h)
            check("el medico lo descontinua", r.status_code == 204, r.status_code)
            d = await estados(medication_id=mid, futuras=True)
            check("sus tomas futuras quedan canceladas",
                  d.get("pending", 0) == 0
                  and d.get("cancelled", 0) == antes.get("pending", 0), (antes, d))
            await generar_dosis(dias=14, verbose=False)
            d = await estados(medication_id=mid, futuras=True)
            check("y el generador no las revive, porque ya no esta vigente",
                  d.get("pending", 0) == 0, d)

        print("--- al cambiarle el horario ---")
        r = await client.post(
            f"/api/v1/patients/{ELENA}/medications", headers=h,
            json={"name": f"{MARCA} Metformina", "dose_amount": 850,
                  "dose_unit": "mg", "times": ["08:00", "20:00"],
                  "start_date": (manana - timedelta(days=1)).isoformat()})
        mid2 = r.json()["medication_id"] if r.status_code == 201 else None
        check("el medico agrega otro", mid2 is not None, r.text[:120])
        if mid2:
            await generar_dosis(dias=14, verbose=False)
            antes = await estados(medication_id=mid2, futuras=True)

            r = await client.patch(
                f"/api/v1/patients/{ELENA}/medications/{mid2}", headers=h,
                json={"times": ["08:00", "14:00"]})
            check("le cambia un horario", r.status_code == 200,
                  f"{r.status_code} {r.text[:120]}")
            await generar_dosis(dias=14, verbose=False)
            horas = (await sql(
                "SELECT DISTINCT to_char(scheduled_at AT TIME ZONE :z, 'HH24:MI') "
                "FROM scheduled_doses WHERE medication_id = CAST(:m AS uuid) "
                "  AND status = 'pending' AND scheduled_at > now() ORDER BY 1",
                m=mid2, z=get_settings().timezone)).scalars().all()
            check("las tomas futuras quedan con el horario nuevo",
                  sorted(horas) == ["08:00", "14:00"], list(horas))
            d = await estados(medication_id=mid2, futuras=True)
            check("la hora que se quito queda cancelada",
                  d.get("cancelled", 0) > 0, d)

            # Deshacer el cambio tiene que devolver la hora, no dejarla
            # cancelada para siempre.
            r = await client.patch(
                f"/api/v1/patients/{ELENA}/medications/{mid2}", headers=h,
                json={"times": ["08:00", "20:00"]})
            await generar_dosis(dias=14, verbose=False)
            horas = (await sql(
                "SELECT DISTINCT to_char(scheduled_at AT TIME ZONE :z, 'HH24:MI') "
                "FROM scheduled_doses WHERE medication_id = CAST(:m AS uuid) "
                "  AND status = 'pending' AND scheduled_at > now() ORDER BY 1",
                m=mid2, z=get_settings().timezone)).scalars().all()
            check("deshacer el cambio revive la hora, no la deja perdida",
                  sorted(horas) == ["08:00", "20:00"], list(horas))

            # Un cambio que no toca la agenda no mueve ninguna toma.
            antes = await estados(medication_id=mid2, futuras=True)
            r = await client.patch(
                f"/api/v1/patients/{ELENA}/medications/{mid2}", headers=h,
                json={"instructions": "Con el desayuno"})
            d = await estados(medication_id=mid2, futuras=True)
            check("cambiar solo las instrucciones no cancela nada",
                  r.status_code == 200 and d == antes, (antes, d))
    finally:
        await sql("UPDATE treatments SET status = 'vigente', effective_to = NULL "
                  "WHERE id = ANY(CAST(:i AS uuid[]))", i=[str(x) for x in vigentes])
        await limpiar()


async def correr():
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport,
                                 base_url="http://testserver", timeout=60) as client:
        await main(client)
    await engine.dispose()
    print(f"\n{ok}/{n} comprobaciones")
    return 0 if ok == n and n > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(correr()))

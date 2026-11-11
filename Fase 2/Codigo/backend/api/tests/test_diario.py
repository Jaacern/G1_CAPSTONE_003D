"""Pruebas del punto de entrada diario."""
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

from app import maintenance as m
from app.config import get_settings
from app.db import engine

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")

async def main():
    # La zona de estos procesos tiene que ser la de la aplicacion, no una
    # propia. Cuando eran dos variables distintas, poner TIMEZONE dejaba la
    # API en un pais y estos procesos en otro, y el desfase salia como
    # dosis duplicadas a una hora de distancia.
    check("la zona es la de la aplicacion",
          m.ZONA == get_settings().timezone, (m.ZONA, get_settings().timezone))
    async with engine.begin() as c:
        sesion = (await c.execute(text("show timezone"))).scalar()
        dia_local = (await c.execute(text("select current_date"))).scalar()
        dia_zona = (await c.execute(text(
            "select CAST(now() AT TIME ZONE :z AS date)"), {"z": m.ZONA})).scalar()
    check("la conexion llega con la zona puesta", sesion == m.ZONA,
          (sesion, m.ZONA))
    check("current_date es el dia local y no el de UTC", dia_local == dia_zona,
          (dia_local, dia_zona))

    orden = [n for n, _ in m.DIARIO]
    check("estan las siete tareas", len(orden) == 7, orden)
    check("las dosis se generan antes de vencerlas",
          orden.index("generar-dosis") < orden.index("marcar-vencidas"), orden)
    check("se vencen antes de alertarlas",
          orden.index("marcar-vencidas") < orden.index("alertar-dosis"), orden)
    check("el semaforo va despues de las tres alertas",
          orden.index("semaforo") > orden.index("alertar-dosis")
          and orden.index("semaforo") > orden.index("alertar-vitales")
          and orden.index("semaforo") > orden.index("alertar-reloj"), orden)

    r = await m.correr_todo(verbose=False)
    check("corre todo sin fallas", r == {"tareas": 7, "fallas": 0}, r)

    # Una tarea que revienta no debe arrastrar a las demas.
    original = m.DIARIO
    llamadas = []
    async def buena(verbose=True):
        llamadas.append("buena")
        return {}
    async def mala(verbose=True):
        raise RuntimeError("se cayo la base")
    m.DIARIO = (("mala", mala), ("buena", buena), ("mala2", mala))
    try:
        r2 = await m.correr_todo(verbose=False)
    finally:
        m.DIARIO = original
    check("sigue con las demas aunque una falle", llamadas == ["buena"], llamadas)
    check("cuenta las fallas", r2 == {"tareas": 3, "fallas": 2}, r2)

    # El codigo de salida tiene que reflejar la falla: el cron lee el
    # codigo, no la salida de texto.
    m.DIARIO = (("mala", mala),)
    try:
        codigo = await m._main(["diario"])
    finally:
        m.DIARIO = original
    check("devuelve 1 cuando algo falla", codigo == 1, codigo)

    codigo = await m._main(["no-existe"])
    check("una tarea inexistente devuelve 2", codigo == 2, codigo)
    codigo = await m._main([])
    check("sin argumentos devuelve 2", codigo == 2, codigo)

    await engine.dispose()
    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

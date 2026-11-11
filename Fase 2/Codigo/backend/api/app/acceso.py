"""Registro de accesos al expediente (RNF-14).

    "El sistema debe registrar que usuario consulto que expediente y cuando."

La tabla record_access_log existia y la escribian tres routers: bitacora,
documentos y archivos. El resto del expediente se podia leer sin dejar
rastro: el perfil, los vitales, los medicamentos, las alertas, el reporte en
PDF, los miembros y las preguntas al asistente.

POR QUE EN UN SOLO LUGAR
    Se pudo agregar una llamada en cada endpoint de lectura, que es como
    estaba hecho. Son mas de veinte, y el siguiente que alguien escriba va a
    nacer sin ella, porque nada obliga a acordarse. Un registro de auditoria
    que depende de la memoria de quien programa tiene huecos, y un hueco aca
    no se nota hasta el dia en que alguien pregunta quien vio un expediente.

    Por eso el registro se hace desde un middleware, a partir de la ruta. Y
    hay una prueba que recorre todas las rutas de la aplicacion y falla si
    aparece una lectura de paciente que no este clasificada en este archivo.

QUE CUENTA COMO UN ACCESO
    Una fila por persona, paciente y seccion cada VENTANA_MINUTOS. Las
    pantallas consultan solas cada pocos segundos (el chat, la salud en
    vivo, el centro de alertas), y registrar cada consulta llenaria la tabla
    de filas identicas que no le dicen nada a nadie. Lo que una auditoria
    necesita saber es que tal persona estuvo mirando los vitales de tal
    paciente a tal hora, no que su telefono pregunto cuarenta veces.

QUE NO SE REGISTRA
    Las escrituras: de esas se ocupa audit_log, que guarda el cambio. Y lo
    que no es expediente clinico, que esta enumerado abajo con su razon.
"""
from __future__ import annotations

import time

from sqlalchemy import text
from starlette.requests import Request

from app.db import SessionLocal

VENTANA_MINUTOS = 5

# Lecturas del expediente, por lo que sigue a /patients/{patient_id} en la
# ruta. El valor es la seccion de record_access_log (ck_record_access_log_section).
SECCIONES: dict[str, str] = {
    "":                         "profile",
    "/emergency-contacts":      "profile",
    "/allergies":               "profile",
    "/immunizations":           "profile",
    "/summary/today":           "profile",
    "/vitals":                  "vitals",
    "/vitals/latest":           "vitals",
    "/vitals/thresholds":       "vitals",
    "/measurements":            "vitals",
    "/wearable/status":         "vitals",
    "/watch/status":            "vitals",
    "/medications":             "medications",
    "/treatments":              "medications",
    "/prn":                     "medications",
    "/prn/uses":                "doses",
    "/doses":                   "doses",
    "/adherence":               "doses",
    "/timeline":                "logbook",
    "/chat/messages":           "chat",
    "/assistant/conversations": "assistant",
    "/report":                  "reports",
    "/members":                 "members",
}

# Las que no son GET pero leen el expediente. Preguntarle al asistente le
# entrega al modelo el expediente completo en nombre de quien pregunta.
LECTURAS_POR_POST: dict[str, str] = {
    "/assistant/messages": "assistant",
}

# Lecturas que ya registran su acceso dentro del propio endpoint. No se tocan
# aca para no dejar dos filas por la misma consulta.
YA_REGISTRAN: frozenset[str] = frozenset({
    "/observations", "/incidents", "/handover-notes",   # logbook.py
    "/documents",                                        # documents.py
})

# Rutas de paciente que no son expediente clinico. Estan aca, a la vista y
# con su razon, para que dejar algo fuera sea una decision y no un olvido.
NO_ES_EXPEDIENTE: frozenset[str] = frozenset({
    "/photos",   # galeria familiar: fotos que la familia le comparte
    "/tasks",    # tareas de cuidado: organizacion del dia, no datos de salud
})


def seccion_de(sufijo: str, metodo: str = "GET") -> str | None:
    """Seccion que corresponde a una ruta de paciente, o None si no se registra."""
    sufijo = sufijo.rstrip("/")
    if metodo == "GET":
        return SECCIONES.get(sufijo)
    if metodo == "POST":
        return LECTURAS_POR_POST.get(sufijo)
    return None


# Ultimo registro de cada (usuario, paciente, seccion), para no ir a la base
# en cada consulta repetida. Es por proceso: con dos replicas puede quedar
# una fila de mas dentro de la ventana, y no importa. La base tiene su propia
# comprobacion igual, asi que un reinicio tampoco duplica.
_recientes: dict[tuple[str, str, str], float] = {}
_MAX_RECIENTES = 20_000


def _visto_hace_poco(clave: tuple[str, str, str]) -> bool:
    ahora = time.monotonic()
    ultimo = _recientes.get(clave)
    if ultimo is not None and ahora - ultimo < VENTANA_MINUTOS * 60:
        return True
    if len(_recientes) >= _MAX_RECIENTES:
        # Se botan los vencidos. Si aun asi no cabe, se parte de cero: perder
        # esta memoria solo cuesta una consulta mas a la base.
        limite = ahora - VENTANA_MINUTOS * 60
        for k in [k for k, v in _recientes.items() if v < limite]:
            del _recientes[k]
        if len(_recientes) >= _MAX_RECIENTES:
            _recientes.clear()
    _recientes[clave] = ahora
    return False


def olvidar_recientes() -> None:
    """Vacia la memoria de accesos recientes. Para las pruebas."""
    _recientes.clear()


async def registrar_acceso(*, patient_id: str, user_id: str, seccion: str,
                           role: str | None = None,
                           request: Request | None = None) -> None:
    """Deja constancia de que [user_id] consulto [seccion] de [patient_id].

    Nunca lanza. Si el registro falla, la consulta ya se respondio y no se le
    puede devolver un error a quien solo queria ver sus datos: se avisa por
    la salida y se sigue.

    Usa su propia sesion, aparte de la del request, para no meterse en la
    transaccion del endpoint ni depender de que haga commit: las lecturas no
    lo hacen.

    [role] es el rol con que accedio. Si no se pasa, se busca la membresia
    viva. Se guarda en la fila porque es un hecho historico: si manana se le
    cambia el rol, la auditoria tiene que seguir diciendo con cual entro.
    """
    clave = (str(user_id), str(patient_id), seccion)
    if _visto_hace_poco(clave):
        return
    try:
        ip = ua = None
        if request is not None:
            ip = request.client.host if request.client else None
            ua = (request.headers.get("user-agent") or "")[:300] or None
        async with SessionLocal() as s:
            await s.execute(
                text(
                    """
                    INSERT INTO record_access_log
                        (patient_id, user_id, role, section, ip_address, user_agent)
                    SELECT CAST(:pid AS uuid), CAST(:uid AS uuid),
                           COALESCE(CAST(:role AS varchar), pm.role),
                           CAST(:sec AS varchar), CAST(:ip AS inet), :ua
                    FROM (SELECT 1) AS uno
                    LEFT JOIN patient_members pm
                           ON pm.patient_id = CAST(:pid AS uuid)
                          AND pm.user_id = CAST(:uid AS uuid)
                          AND pm.removed_at IS NULL
                    WHERE COALESCE(CAST(:role AS varchar), pm.role) IS NOT NULL
                      AND NOT EXISTS (
                            SELECT 1 FROM record_access_log r
                             WHERE r.patient_id = CAST(:pid AS uuid)
                               AND r.user_id = CAST(:uid AS uuid)
                               AND r.section = CAST(:sec AS varchar)
                               AND r.accessed_at > now()
                                   - make_interval(mins => CAST(:ventana AS integer))
                          )
                    LIMIT 1
                    """
                ),
                {"pid": str(patient_id), "uid": str(user_id), "role": role,
                 "sec": seccion, "ip": ip, "ua": ua, "ventana": VENTANA_MINUTOS},
            )
            await s.commit()
    except Exception as e:  # noqa: BLE001
        _recientes.pop(clave, None)
        print(f"[acceso] no se pudo registrar {seccion} de {patient_id}: "
              f"{str(e).splitlines()[0]}")


async def middleware_de_accesos(request: Request, call_next):
    """Registra las lecturas del expediente que respondieron bien.

    Quien es la persona y con que rol entro lo deja get_patient_member en
    request.state al validar la membresia. Si no esta, la ruta no era de un
    paciente o la persona no paso el control de acceso, y no hay nada que
    registrar: un intento rechazado no es una consulta.
    """
    response = await call_next(request)
    try:
        ctx = getattr(request.state, "paciente", None)
        if ctx is None or response.status_code >= 400:
            return response
        _, _, sufijo = request.url.path.partition(f"/patients/{ctx.patient_id}")
        seccion = seccion_de(sufijo, request.method)
        if seccion is not None:
            await registrar_acceso(patient_id=ctx.patient_id,
                                   user_id=ctx.user.user_id, role=ctx.role,
                                   seccion=seccion, request=request)
    except Exception as e:  # noqa: BLE001
        print(f"[acceso] fallo el registro: {str(e).splitlines()[0]}")
    return response

"""Reparto de los avisos de las alertas.

    python -m app.avisos pasada     una vuelta y termina
    python -m app.avisos vigilar    en bucle, lo que corre el contenedor

EL PROBLEMA QUE RESUELVE
    Las alertas se creaban y nadie se enteraba. Una caida, un SOS o una
    saturacion baja quedaban guardados en la base esperando a que alguien
    abriera la aplicacion en el centro de alertas. Los requisitos piden lo
    contrario: que el telefono suene (RF-45), que una caida avise en menos
    de diez segundos (RNF-04) y que una alerta critica que nadie atiende no
    se quede callada (RF-52).

TRES PASOS, SIEMPRE EN ESTE ORDEN
    1. repartir   Toma las alertas que todavia no se repartieron y deja una
                  entrega en cola por cada telefono de cada persona a quien
                  le corresponde.
    2. enviar     Manda lo que hay en cola por el proveedor de push y anota
                  como le fue a cada entrega.
    3. reavisar   Vuelve a poner en cola las criticas que siguen sin atender
                  pasado el plazo.

POR QUE LA COLA ESTA EN LA BASE
    alert_deliveries ya existia para registrar cada intento, que es lo que
    permite medir las latencias de RNF-04 y RNF-05. Usarla tambien como cola
    evita un servicio mas: la entrega nace 'queued' y pasa a 'sent' o a
    'failed'. Si el proceso se cae a medio envio, lo que quedo en cola sigue
    en cola y sale en la pasada siguiente.

QUIEN LLAMA
    Los endpoints que crean una alerta llaman a despachar() al terminar, en
    segundo plano, asi el aviso sale en el momento y no cuando toque la
    pasada. Y aparte corre vigilar() en su propio contenedor, que hace las
    veces de red de seguridad y es quien se ocupa de los reavisos, que no
    dependen de ningun request.

    Se puede llamar desde varios lados a la vez sin duplicar nada. Cada paso
    toma su trabajo con un candado de la base (un UPDATE que exige que nadie
    mas la haya tomado, o FOR UPDATE SKIP LOCKED), asi dos procesos nunca
    reparten la misma alerta ni envian la misma entrega.

A QUIEN SE AVISA
    A los familiares y cuidadoras del circulo del paciente. Al medico no: su
    participacion es acotada y ve las alertas cuando entra al expediente, no
    en el telefono a las tres de la manana por la dosis de las dos. El adulto
    mayor tampoco, es el paciente.

    Se respeta la preferencia de cada persona por tipo de alerta
    (notification_settings). Caida y SOS no se pueden apagar: eso lo
    garantiza un CHECK de esa tabla, no este archivo.

    A quien genero la alerta no se le avisa de su propia accion: la cuidadora
    que apreto el boton de emergencia ya sabe que lo apreto.
"""
from __future__ import annotations

import asyncio
import os
import sys

from sqlalchemy import text

from app.db import engine
from app.email_provider import get_email
from app.push_provider import get_push

# Quienes reciben el aviso en el telefono. Un solo lugar, a proposito: es una
# decision del producto y tiene que poder cambiarse sin buscar por el codigo.
ROLES_AVISADOS = ("family", "caregiver")

# Una alerta mas vieja que esto ya no se reparte: se marca como repartida y
# no se envia nada. Evita que la primera vez que corre esto en una base con
# historia, o despues de una caida larga del servicio, salgan de golpe los
# avisos atrasados de una semana.
MAX_EDAD_MINUTOS = 60

# Lo mismo para una entrega que se quedo en cola: pasada una hora, avisar de
# la dosis de las dos a las cinco confunde mas de lo que ayuda.
VENCE_EN_COLA_MINUTOS = 60

# Entregas por pasada y envios simultaneos. Con el candado tomado durante el
# envio, un lote chico es lo que deja pasar rapido a una critica que llega
# mientras se esta enviando otra cosa.
LOTE = 100
SIMULTANEOS = 10

_SIN_TELEFONO = "La persona no tiene un telefono registrado para recibir avisos."

_DESTINATARIOS = """
    SELECT pm.user_id
    FROM patient_members pm
    JOIN users u ON u.id = pm.user_id
    WHERE pm.patient_id = CAST(:pid AS uuid)
      AND pm.removed_at IS NULL
      AND pm.role = ANY(CAST(:roles AS varchar[]))
      AND u.is_active = true
      AND u.deleted_at IS NULL
      AND pm.user_id IS DISTINCT FROM CAST(:autor AS uuid)
      AND NOT EXISTS (
            SELECT 1 FROM notification_settings ns
             WHERE ns.user_id = pm.user_id
               AND ns.alert_type = CAST(:tipo AS varchar)
               AND ns.push_enabled = false
          )
"""


async def _parametro(conn, clave: str, por_defecto: int) -> int:
    v = (await conn.execute(
        text("SELECT value FROM system_parameters WHERE key = :k"),
        {"k": clave})).scalar()
    try:
        return int(v)
    except (TypeError, ValueError):
        return por_defecto


async def _encolar(conn, alerta, ronda: int) -> int:
    """Deja en cola una entrega por cada telefono de cada destinatario.

    Quien no tiene ningun telefono registrado no desaparece: le queda una
    entrega fallida con el motivo. Es la constancia de que a esa persona no
    se le pudo avisar, y es de donde parte la via alternativa de RF-82.
    """
    autor = (await conn.execute(
        text(
            """
            SELECT triggered_by FROM sos_events
             WHERE alert_id = CAST(:aid AS uuid)
            UNION ALL
            SELECT reported_by FROM incidents
             WHERE alert_id = CAST(:aid AS uuid)
            LIMIT 1
            """
        ),
        {"aid": str(alerta["id"])})).scalar()

    r = await conn.execute(
        text(
            f"""
            INSERT INTO alert_deliveries
                (alert_id, user_id, push_device_id, channel, status,
                 error_detail, notice_round)
            SELECT CAST(:aid AS uuid), d.user_id, pd.id, 'push',
                   CASE WHEN pd.id IS NULL THEN 'failed' ELSE 'queued' END,
                   CASE WHEN pd.id IS NULL
                        THEN CAST(:sin_telefono AS varchar) END,
                   CAST(:ronda AS smallint)
            FROM ({_DESTINATARIOS}) d
            LEFT JOIN push_devices pd
                   ON pd.user_id = d.user_id AND pd.is_active
            """
        ),
        {"aid": str(alerta["id"]), "pid": str(alerta["patient_id"]),
         "roles": list(ROLES_AVISADOS), "tipo": alerta["type"],
         "autor": str(autor) if autor else None,
         "sin_telefono": _SIN_TELEFONO, "ronda": ronda},
    )
    return r.rowcount or 0


async def repartir() -> dict[str, int]:
    """Paso 1. Alertas sin repartir pasan a entregas en cola."""
    async with engine.begin() as conn:
        # Tomarlas y marcarlas es una sola sentencia. Si dos procesos llegan
        # a la vez, la base le entrega cada alerta a uno solo.
        tomadas = (await conn.execute(
            text(
                """
                UPDATE alerts SET notified_at = now()
                 WHERE notified_at IS NULL
                RETURNING id, patient_id, type,
                          created_at > now()
                              - make_interval(mins => CAST(:edad AS integer))
                              AS reciente
                """
            ),
            {"edad": MAX_EDAD_MINUTOS})).mappings().all()

        entregas = viejas = 0
        for a in tomadas:
            if not a["reciente"]:
                viejas += 1
                continue
            entregas += await _encolar(conn, a, ronda=0)
    return {"alertas": len(tomadas) - viejas, "viejas": viejas,
            "entregas": entregas}


async def reavisar_criticas() -> dict[str, int]:
    """Paso 3. Vuelve a avisar de las criticas que nadie atendio (RF-52).

    No hay "siguientes contactos" a quienes escalar: desde 406 los contactos
    no tienen orden y en una emergencia se avisa a todos por igual. Lo que
    queda del requisito, y lo que protege al paciente, es insistir. Mientras
    una alerta critica siga activa, se vuelve a avisar a todos cada
    alert_escalation_minutes.

    Atender la alerta lo corta (RF-48): solo se miran las que siguen
    'active'. Tambien tiene techo, alert_renotify_max, porque un telefono que
    suena cada quince minutos durante tres dias deja de leerse como un aviso.
    Y no toca alertas mas viejas que todo el ciclo de reavisos, para no
    ponerse a insistir sobre una emergencia de la semana pasada.
    """
    async with engine.begin() as conn:
        espera = await _parametro(conn, "alert_escalation_minutes", 15)
        maximo = await _parametro(conn, "alert_renotify_max", 8)

        pendientes = (await conn.execute(
            text(
                """
                UPDATE alerts
                   SET escalated_at = now(),
                       renotify_count = renotify_count + 1
                 WHERE status = 'active'
                   AND severity = 'critical'
                   AND notified_at IS NOT NULL
                   AND renotify_count < CAST(:maximo AS integer)
                   AND coalesce(escalated_at, notified_at) <= now()
                       - make_interval(mins => CAST(:espera AS integer))
                   AND created_at > now() - make_interval(
                       mins => CAST(:espera AS integer)
                               * (CAST(:maximo AS integer) + 2))
                RETURNING id, patient_id, type, renotify_count
                """
            ),
            {"espera": espera, "maximo": maximo})).mappings().all()

        entregas = 0
        for a in pendientes:
            entregas += await _encolar(conn, a, ronda=a["renotify_count"])
    return {"alertas": len(pendientes), "entregas": entregas}


def _texto(f) -> tuple[str, str]:
    """Titulo y cuerpo de la notificacion.

    El titulo lleva el nombre del paciente adelante: quien cuida a dos
    personas necesita saber de cual se trata sin abrir la aplicacion. En un
    reaviso se dice que sigue sin atender, que es la unica razon por la que
    el telefono vuelve a sonar.
    """
    titulo = f"{f['first_name']} · {f['title']}"
    if f["notice_round"] > 0:
        titulo = f"Sin atender · {titulo}"
    cuerpo = (f["detail"] or f["title"]).strip()
    return titulo[:110], cuerpo[:240]


async def enviar_cola() -> dict[str, int]:
    """Paso 2. Manda lo que hay en cola y anota el resultado de cada entrega."""
    proveedor = get_push()
    enviadas = fallidas = 0

    async with engine.begin() as conn:
        filas = (await conn.execute(
            text(
                """
                SELECT d.id, d.alert_id, d.notice_round,
                       d.created_at < now()
                           - make_interval(mins => CAST(:vence AS integer))
                           AS vencida,
                       pd.id AS device_id, pd.push_token, pd.is_active,
                       a.type, a.severity, a.title, a.detail, a.patient_id,
                       p.first_name
                FROM alert_deliveries d
                JOIN alerts a   ON a.id = d.alert_id
                JOIN patients p ON p.id = a.patient_id
                LEFT JOIN push_devices pd ON pd.id = d.push_device_id
                WHERE d.status = 'queued' AND d.channel = 'push'
                -- Las criticas primero: si hay cola, una caida no espera
                -- detras de veinte avisos de dosis.
                ORDER BY (a.severity = 'critical') DESC, d.created_at
                LIMIT :lote
                FOR UPDATE OF d SKIP LOCKED
                """
            ),
            {"vence": VENCE_EN_COLA_MINUTOS, "lote": LOTE})).mappings().all()

        semaforo = asyncio.Semaphore(SIMULTANEOS)

        async def uno(f):
            if f["vencida"]:
                return f, None, "Vencio en la cola sin enviarse."
            if not f["push_token"] or not f["is_active"]:
                return f, None, "El aparato ya no esta activo."
            titulo, cuerpo = _texto(f)
            async with semaforo:
                try:
                    r = await proveedor.enviar(
                        token=f["push_token"], titulo=titulo, cuerpo=cuerpo,
                        canal="falls" if f["type"] == "fall" else "alerts",
                        critica=f["severity"] == "critical",
                        datos={"type": "alert", "alert_type": f["type"],
                               "alert_id": str(f["alert_id"]),
                               "patient_id": str(f["patient_id"]),
                               "severity": f["severity"],
                               "delivery_id": str(f["id"])},
                    )
                except Exception as e:  # noqa: BLE001
                    # El contrato dice que el proveedor no lanza, pero un
                    # proveedor con un error no puede dejar la cola trabada.
                    return f, None, f"Fallo el proveedor: {str(e).splitlines()[0]}"
            return f, r, None

        for f, r, motivo in await asyncio.gather(*(uno(f) for f in filas)):
            if r is not None and r.ok:
                await conn.execute(
                    text("UPDATE alert_deliveries SET status = 'sent', "
                         "sent_at = now() WHERE id = :id"), {"id": f["id"]})
                enviadas += 1
                continue
            error = motivo or (r.error if r else None) or "No se pudo enviar."
            await conn.execute(
                text("UPDATE alert_deliveries SET status = 'failed', "
                     "error_detail = :e WHERE id = :id"),
                {"id": f["id"], "e": error[:300]})
            fallidas += 1
            if r is not None and r.token_invalido and f["device_id"]:
                # El token murio: se deja de usar ese aparato. No se borra,
                # igual que al cerrar sesion.
                await conn.execute(
                    text("UPDATE push_devices SET is_active = false "
                         "WHERE id = :id"), {"id": f["device_id"]})

            # RF-82: si el push falló y hay correo configurado, se intenta
            # enviar por esa vía como canal alternativo.
            if get_email().disponible:
                asyncio.create_task(_correo_alternativo(f, error))

    return {"enviadas": enviadas, "fallidas": fallidas}


async def _correo_alternativo(f: dict, motivo_push: str) -> None:
    """RF-82: vía alternativa por correo cuando el push falla.

    Se obtiene el correo del destinatario y se envía un aviso simple.
    No bloquea la cola de push: corre como tarea paralela.
    Nunca lanza: si el correo también falla, se anota y se sigue.
    """
    async with engine.connect() as conn:
        email_row = (await conn.execute(
            text("SELECT email, full_name FROM users WHERE id = :uid"),
            {"uid": str(f["user_id"])},
        )).mappings().first()

    if not email_row or not email_row["email"]:
        return

    titulo, cuerpo_notif = _texto(f)
    nombre = email_row["full_name"] or email_row["email"]

    cuerpo_html = f"""
    <html><body style="font-family:sans-serif;color:#222;">
    <h2 style="color:#d32f2f;">&#9888;&#65039; {titulo}</h2>
    <p>Hola, <strong>{nombre}</strong>.</p>
    <p>{cuerpo_notif}</p>
    <p style="font-size:0.85rem;color:#888;">
      Esta notificación llegó por correo porque no se pudo enviar al teléfono.<br>
      Abre la app AgeCare para ver los detalles y atender la alerta.
    </p>
    <hr><p style="font-size:0.8rem;color:#aaa;">AgeCare · Cuidando a quienes cuidaron de nosotros.</p>
    </body></html>
    """
    cuerpo_texto = (
        f"{titulo}\n\n{cuerpo_notif}\n\n"
        "Esta notificación llegó por correo porque no se pudo enviar al teléfono.\n"
        "Abre la app AgeCare para ver los detalles.\n\n— AgeCare"
    )

    try:
        resultado = await get_email().enviar(
            destinatario=email_row["email"],
            asunto=f"[AgeCare] {titulo}",
            cuerpo_html=cuerpo_html,
            cuerpo_texto=cuerpo_texto,
        )
        if not resultado.ok:
            print(
                f"[avisos] correo alternativo fallido para "
                f"{email_row['email']}: {resultado.error}"
            )
    except Exception as e:  # noqa: BLE001
        print(f"[avisos] excepción en correo alternativo: "
              f"{str(e).splitlines()[0]}")


async def despachar() -> dict[str, int]:
    """Reparte y envia. Es lo que llaman los endpoints al crear una alerta.

    Nunca lanza. Corre despues de que el request ya respondio: la alerta esta
    guardada y un error aca no se le puede devolver a nadie. Si falla, se
    avisa por la salida y lo que quedo pendiente sale en la pasada siguiente
    de vigilar().
    """
    try:
        r1 = await repartir()
        r2 = await enviar_cola()
        return {"alertas": r1["alertas"], "entregas": r1["entregas"], **r2}
    except Exception as e:  # noqa: BLE001
        print(f"[avisos] fallo el despacho: {str(e).splitlines()[0]}")
        return {"alertas": 0, "entregas": 0, "enviadas": 0, "fallidas": 0}


async def pasada(*, verbose: bool = True) -> dict[str, int]:
    """Una vuelta completa: reavisos pendientes, reparto y envio."""
    reavisos = await reavisar_criticas()
    r = await despachar()
    if verbose and (reavisos["alertas"] or r["alertas"] or r["enviadas"]
                    or r["fallidas"]):
        print(f"[avisos] alertas nuevas {r['alertas']}, reavisos "
              f"{reavisos['alertas']}, enviadas {r['enviadas']}, "
              f"fallidas {r['fallidas']}")
    return {"reavisos": reavisos["alertas"], **r}


async def vigilar(intervalo: int) -> None:
    """Bucle del contenedor de avisos."""
    disponible = get_push().disponible
    print(f"[avisos] cada {intervalo}s, proveedor de push "
          f"{'encendido' if disponible else 'APAGADO (PUSH_PROVIDER=none)'}")
    while True:
        try:
            await pasada()
        except Exception as e:  # noqa: BLE001
            print(f"[avisos] la pasada fallo: {str(e).splitlines()[0]}")
        await asyncio.sleep(intervalo)


async def _main(argv: list[str]) -> int:
    if argv == ["pasada"]:
        try:
            await pasada()
        finally:
            await engine.dispose()
        return 0
    if argv == ["vigilar"]:
        await vigilar(int(os.environ.get("AVISOS_INTERVALO_SEG", "30")))
        return 0
    print("uso: python -m app.avisos <pasada | vigilar>")
    return 2


if __name__ == "__main__":
    sys.exit(asyncio.run(_main(sys.argv[1:])))

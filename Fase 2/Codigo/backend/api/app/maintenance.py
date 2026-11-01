"""Tareas de mantenimiento que la aplicacion necesita que alguien corra.

Se corren desde afuera, no desde un request:

    python -m app.maintenance barrer-subidas
    python -m app.maintenance generar-dosis
    python -m app.maintenance marcar-vencidas
    python -m app.maintenance alertar-dosis
    python -m app.maintenance alertar-vitales
    python -m app.maintenance semaforo

No se exponen como endpoints a proposito: no son acciones de un usuario,
no tienen a quien responderle, y un endpoint de mantenimiento abierto es
justo la clase de puerta que uno no quiere tener en una aplicacion con
datos de salud.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys

from sqlalchemy import text

from app.db import engine
from app.storage import get_storage

# Margen despues del vencimiento antes de dar la subida por perdida. El
# enlace vence a los 15 minutos, pero el PUT puede estar en curso justo en
# ese momento: un PDF de 20 MB por el dato movil de la casa de un paciente
# tarda. Marcarlo vencido mientras los bytes van llegando seria arruinar una
# subida que iba bien.
GRACIA_MINUTOS = 30

# Zona horaria de la operacion. medication_times guarda "las 8 de la manana"
# como hora local, no como instante, asi que para convertirla hace falta
# saber de que pais se habla. Se deja en una variable de entorno porque es
# lo unico de aca que cambiaria si manana el servicio opera en otro pais,
# pero el valor por defecto es el real: AgeCare opera en Chile.
ZONA = os.getenv("AGECARE_TIMEZONE", "America/Santiago")


async def barrer_subidas_vencidas(*, verbose: bool = True) -> dict[str, int]:
    """Marca expired las subidas que vencieron sin completarse.

    Devuelve cuantas filas se marcaron y cuantos binarios huerfanos se
    borraron del almacenamiento.

    Un binario huerfano es el caso raro pero posible de que el PUT haya
    guardado el archivo y la actualizacion de la fila haya fallado despues
    (se cayo la base, se corto el proceso). Queda un archivo en disco que
    nadie va a volver a nombrar nunca, porque su fila dice que no llego.
    Ese se borra: no es informacion, es basura que ocupa espacio.

    Las FILAS no se borran, solo cambian de estado. La constancia de que
    alguien intento subir algo al expediente de un paciente se conserva.
    """
    storage = get_storage()
    marcadas = 0
    huerfanos = 0

    async with engine.begin() as conn:
        vencidas = (
            await conn.execute(
                text(
                    """
                    SELECT id, storage_key
                    FROM files
                    WHERE status = 'pending'
                      AND upload_expires_at < now() - make_interval(mins => :gracia)
                    ORDER BY upload_expires_at
                    """
                ),
                {"gracia": GRACIA_MINUTOS},
            )
        ).mappings().all()

        for f in vencidas:
            # Primero el disco y despues la fila. Si se cae en medio, la fila
            # sigue pending y la proxima corrida la vuelve a tomar. Al reves
            # quedaria un binario que ya nadie puede nombrar.
            try:
                if storage.exists(storage_key=f["storage_key"]):
                    await storage.delete(storage_key=f["storage_key"])
                    huerfanos += 1
            except Exception as e:  # noqa: BLE001
                # Que un archivo no se pueda borrar no debe detener el
                # barrido de los otros cien.
                if verbose:
                    print(f"  no se pudo borrar {f['storage_key']}: {e}")

            await conn.execute(
                text(
                    """
                    UPDATE files
                       SET status = 'expired', updated_at = now()
                     WHERE id = :id AND status = 'pending'
                    """
                ),
                {"id": str(f["id"])},
            )
            marcadas += 1

    if verbose:
        print(f"subidas vencidas marcadas : {marcadas}")
        print(f"binarios huerfanos borrados: {huerfanos}")

    return {"marcadas": marcadas, "huerfanos": huerfanos}


async def generar_dosis(*, dias: int = 14, verbose: bool = True) -> dict[str, int]:
    """Crea las dosis programadas de los proximos dias.

    POR QUE HACE FALTA
        scheduled_doses es lo que la pantalla muestra como "lo que toca
        hoy" y es contra lo que se mide la adherencia. Nadie la llenaba.
        El medicamento guarda sus horas en medication_times y sus dias en
        medication_days, pero la fila concreta de "losartan, manana a las
        20:00" tiene que existir para que alguien pueda marcarla.

        Sin esto la pantalla de medicamentos sale vacia y la adherencia da
        cero, aunque los medicamentos esten bien cargados. El UNIQUE
        (medication_id, scheduled_at) de la tabla se escribio pensando en
        este proceso: dice "un slot por medicamento y hora".

    LA HORA
        time_of_day es hora chilena, no UTC. "Las 8 de la manana" no es un
        instante fijo: en enero son las 11:00 UTC y en julio las 12:00,
        porque Chile cambia la hora. Por eso la conversion la hace
        Postgres con AT TIME ZONE y no Python armando el instante a mano:
        asi la dosis cae a las 8 de la manana de la senora todo el anio,
        y no se corre una hora en marzo.

        Es la misma expresion que usa el seed. Si fuera distinta, las
        dosis generadas no chocarian con las sembradas y quedarian dos
        filas para la misma toma, a una hora de distancia.

    QUE NO HACE
        No toca ninguna fila existente. Lo unico que hace es insertar las
        que faltan, y ON CONFLICT DO NOTHING descarta las que ya estan.
        Correrlo dos veces seguidas, o todos los dias, es inofensivo: la
        segunda vez no crea nada. Tampoco hay que llevar la cuenta de
        hasta donde se genero.

        Se generan tambien los slots de hoy que ya pasaron. Si el proceso
        corre a mediodia, la toma de las 08:00 tiene que existir para
        poder quedar como no administrada; saltarsela seria borrar del
        historial una dosis que al paciente le tocaba.
    """
    async with engine.begin() as conn:
        r = await conn.execute(
            text(
                """
                INSERT INTO scheduled_doses (medication_id, scheduled_at, status)
                SELECT m.id,
                       (CAST(g.d AS date) + t.time_of_day)
                           AT TIME ZONE CAST(:zona AS text),
                       'pending'
                FROM medications m
                JOIN medication_times t ON t.medication_id = m.id
                CROSS JOIN generate_series(
                    CAST(now() AT TIME ZONE CAST(:zona AS text) AS date),
                    CAST(now() AT TIME ZONE CAST(:zona AS text) AS date)
                        + CAST(:dias AS integer),
                    interval '1 day'
                ) AS g(d)
                WHERE m.discontinued_at IS NULL
                  AND (m.start_date IS NULL OR CAST(g.d AS date) >= m.start_date)
                  AND (m.end_date   IS NULL OR CAST(g.d AS date) <= m.end_date)
                  -- Un medicamento sin dias declarados es de todos los dias:
                  -- es lo que asume medications.py cuando la pantalla no
                  -- manda ninguno (_DEFAULT_DAYS). Si aca se exigiera la
                  -- fila en medication_days, ese medicamento no generaria
                  -- dosis nunca y nadie entenderia por que.
                  AND (
                        NOT EXISTS (SELECT 1 FROM medication_days md
                                     WHERE md.medication_id = m.id)
                     OR EXISTS (SELECT 1 FROM medication_days md
                                 WHERE md.medication_id = m.id
                                   AND md.day_of_week = EXTRACT(isodow FROM g.d))
                  )
                ON CONFLICT (medication_id, scheduled_at) DO NOTHING
                """
            ),
            {"zona": ZONA, "dias": dias},
        )
        creadas = r.rowcount or 0

        vigentes = (
            await conn.execute(
                text(
                    """
                    SELECT count(DISTINCT m.id)
                    FROM medications m
                    JOIN medication_times t ON t.medication_id = m.id
                    WHERE m.discontinued_at IS NULL
                      AND (m.end_date IS NULL
                           OR m.end_date >= CAST(now() AT TIME ZONE CAST(:zona AS text)
                                                 AS date))
                    """
                ),
                {"zona": ZONA},
            )
        ).scalar() or 0

    if verbose:
        print(f"medicamentos vigentes : {vigentes}")
        print(f"dosis creadas         : {creadas}")
    return {"medicamentos": int(vigentes), "creadas": creadas}


async def _parametro(conn, clave: str, por_defecto: int) -> int:
    """Lee un umbral de negocio de system_parameters.

    Esos valores viven en la tabla justamente para poder cambiarlos sin
    redespliegue (lo dice el comentario de la tabla). Si falta la fila se
    usa el valor por defecto en vez de reventar: un proceso de
    mantenimiento que se cae porque alguien borro una fila de
    configuracion es peor que uno que sigue con el valor conocido.
    """
    v = (
        await conn.execute(
            text("SELECT value FROM system_parameters WHERE key = :k"),
            {"k": clave},
        )
    ).scalar()
    try:
        return int(v)
    except (TypeError, ValueError):
        return por_defecto


async def marcar_dosis_vencidas(*, verbose: bool = True) -> dict[str, int]:
    """Pasa a 'missed' las dosis cuyo plazo vencio sin que nadie las registre.

    POR QUE HACE FALTA
        Una dosis se crea 'pending' y ahi se queda para siempre si nadie
        la toca. La adherencia cuenta 'taken' contra 'missed' y 'skipped',
        asi que una toma que nunca se dio quedaba como pendiente y no
        bajaba la adherencia: el indicador mostraba 100% de un paciente al
        que no le dieron nada en tres dias. El semaforo tampoco se
        enteraba, porque mira las dosis 'missed' del dia.

    CUANTO SE ESPERA
        grace_window_min, del propio medicamento (una hora por defecto, y
        la pantalla deja ponerle entre 5 minutos y 4 horas). No es un
        numero global a proposito: a una insulina con horario estricto no
        se le puede dar el mismo margen que a una vitamina.

    LA DIFERENCIA CON MARCARLA A MANO
        Cuando la cuidadora marca una dosis como no administrada, el
        endpoint le exige un motivo y guarda quien y cuando. Aca no hay
        nadie, asi que logged_by y logged_at quedan en NULL, y eso es
        informacion y no un hueco: una dosis 'missed' con logged_by es
        "no se la di, por esto"; sin logged_by es "se paso la hora y nadie
        dijo nada". Son dos hechos distintos y conviene poder separarlos
        despues. Los CHECK de la tabla lo permiten: solo exigen logged_at
        para 'taken' y 'skipped'.

    LAS POSPUESTAS
        Una dosis pospuesta tiene su propio plazo, postponed_until, y se
        mide contra ese. Hoy la aplicacion no pospone nada, pero el
        endpoint lo acepta y la tabla lo guarda, asi que si alguna llega
        por ahi no se queda colgada para siempre.
    """
    async with engine.begin() as conn:
        r = await conn.execute(
            text(
                """
                UPDATE scheduled_doses sd
                   SET status = 'missed', updated_at = now()
                  FROM medications m
                 WHERE m.id = sd.medication_id
                   AND sd.status IN ('pending', 'postponed')
                   AND coalesce(sd.postponed_until, sd.scheduled_at)
                       + make_interval(mins => m.grace_window_min) < now()
                """
            )
        )
        marcadas = r.rowcount or 0

    if verbose:
        print(f"dosis vencidas marcadas : {marcadas}")
    return {"marcadas": marcadas}


async def alertar_dosis_omitidas(*, verbose: bool = True) -> dict[str, int]:
    """Crea la alerta de dosis no administrada que nadie estaba creando.

    POR QUE HACE FALTA
        El tipo 'missed_dose' esta en la tabla, en el catalogo de tipos del
        router y en las preferencias de notificacion, donde la familia
        puede activarlo o apagarlo. Lo unico que faltaba era que alguien lo
        creara: la unica alerta que nacia sola era el SOS. Una familia que
        prendia el aviso de dosis no administrada no recibia ninguno nunca.

    UNA ALERTA POR DOSIS, Y UNA SOLA
        La condicion es la toma concreta, asi que el dose_id va en payload
        y se consulta ahi antes de crear. Una dosis no puede juntar dos
        alertas ni hoy ni dentro de un mes, por mas veces que corra el
        proceso.

        Encima de eso se respeta alert_dedup_minutes de system_parameters,
        que es el parametro escrito para esto: si al paciente ya se le
        creo una alerta de dosis en esa ventana, las siguientes esperan.
        Y esperan, no se pierden: como el que manda es el dose_id, en la
        corrida siguiente, con la ventana cumplida, se crean igual. Sirve
        para no mandarle siete avisos de golpe a la familia cuando la
        cuidadora no fue en todo el dia, sin dejar ninguna toma sin avisar.

    El texto sigue el formato que ya tienen las alertas sembradas, para
    que el centro de alertas se lea parejo: "Metformina 850 mg de las
    14:00 sin registro."
    """
    creadas = omitidas = 0

    async with engine.begin() as conn:
        ventana = await _parametro(conn, "alert_dedup_minutes", 30)

        pendientes = (
            await conn.execute(
                text(
                    """
                    SELECT sd.id, sd.scheduled_at, m.patient_id,
                           m.id AS medication_id, m.name, m.dose_text,
                           to_char(sd.scheduled_at AT TIME ZONE
                                   CAST(:zona AS text), 'HH24:MI') AS hora
                    FROM scheduled_doses sd
                    JOIN medications m ON m.id = sd.medication_id
                    JOIN patients   p ON p.id = m.patient_id
                    WHERE sd.status = 'missed'
                      AND p.deleted_at IS NULL
                      -- Las de la cuidadora no llevan alerta: ella ya sabe
                      -- que no la dio, lo acaba de escribir con su motivo.
                      AND sd.logged_by IS NULL
                      AND NOT EXISTS (
                            SELECT 1 FROM alerts a
                             WHERE a.type = 'missed_dose'
                               AND a.payload ->> 'dose_id' = CAST(sd.id AS text)
                          )
                    ORDER BY sd.scheduled_at
                    """
                ),
                {"zona": ZONA},
            )
        ).mappings().all()

        for d in pendientes:
            reciente = (
                await conn.execute(
                    text(
                        """
                        SELECT 1 FROM alerts
                         WHERE patient_id = :pid
                           AND dedup_key = 'missed_dose'
                           AND created_at > now()
                               - make_interval(mins => CAST(:ventana AS integer))
                         LIMIT 1
                        """
                    ),
                    {"pid": str(d["patient_id"]), "ventana": ventana},
                )
            ).first()
            if reciente is not None:
                omitidas += 1
                continue

            detalle = (f"{d['name']} {d['dose_text']} de las {d['hora']} "
                       "sin registro.")
            await conn.execute(
                text(
                    """
                    INSERT INTO alerts
                        (patient_id, type, severity, title, detail,
                         payload, dedup_key, status)
                    VALUES
                        (:pid, 'missed_dose', 'warning',
                         'Dosis no administrada', :detalle,
                         CAST(:payload AS jsonb), 'missed_dose', 'active')
                    """
                ),
                {
                    "pid": str(d["patient_id"]),
                    "detalle": detalle,
                    "payload": json.dumps({
                        "dose_id": str(d["id"]),
                        "medication_id": str(d["medication_id"]),
                        "medication": d["name"],
                        "dose": d["dose_text"],
                        "scheduled_at": d["scheduled_at"].isoformat(),
                    }),
                },
            )
            creadas += 1

    if verbose:
        print(f"alertas de dosis creadas : {creadas}")
        print(f"en espera por la ventana : {omitidas}")
    return {"creadas": creadas, "en_espera": omitidas}


def _numero(v) -> str:
    """Formatea una medicion como la escribiria una persona.

    En la base los valores son numeric, asi que 89 llega como 89.00 y
    escribirlo tal cual en una alerta ("SpO2 89.00%") se lee a maquina.
    Los decimales se conservan cuando existen de verdad: 90.5 importa.
    """
    f = float(v)
    return str(int(f)) if f == int(f) else f"{f:g}"


async def alertar_vitales_fuera_de_rango(*, verbose: bool = True) -> dict[str, int]:
    """Crea la alerta cuando la ultima medicion se sale del umbral.

    POR QUE HACE FALTA
        Los umbrales existen, la familia los configura desde la aplicacion
        y el semaforo los usa. Pero nadie avisaba: la pantalla pintaba el
        valor en rojo si uno entraba a mirarla, y eso es al reves de para
        que sirve un umbral. El sentido de poner un minimo de saturacion
        es que alguien se entere sin tener que estar mirando.

        El propio router lo dice donde recibe las mediciones del wearable:
        "el motor de alertas es un componente aparte; aun no dispara nada
        aqui". Esto es ese componente.

    LA MISMA REGLA QUE LA PANTALLA
        Fuera de rango es valor < minimo o valor > maximo, estricto: el
        valor justo en el borde esta dentro. Es la regla de _in_range en
        vitals.py, y tiene que ser la misma o la pantalla y la alerta se
        contradicen delante de la familia.

        Se mira solo la ultima medicion de cada tipo, no el historial. Un
        valor de hace tres dias que ya se corrigio no es una alerta, es
        historia.

        Solo la medicion principal. La presion arterial guarda la diastolica
        en value_secondary, pero vital_thresholds no tiene umbral para
        ella, asi que no hay contra que compararla. La pantalla tampoco la
        compara.

    LO VIEJO NO ALERTA
        Una medicion vieja no genera alerta: se usa wearable_offline_minutes
        como limite, que es el punto en que el propio sistema ya considera
        que del wearable no estan llegando datos. Sin ese corte, la primera
        corrida en una base con historial abriria alertas por mediciones
        de hace semanas.

    Una alerta por medicion, igual que con las dosis: el reading_id va en
    payload y se consulta ahi. Encima, alert_dedup_minutes por paciente y
    condicion, para que una saturacion que oscila alrededor del minimo no
    abra una alerta por cada lectura del reloj.
    """
    creadas = omitidas = 0

    async with engine.begin() as conn:
        ventana  = await _parametro(conn, "alert_dedup_minutes", 30)
        vigencia = await _parametro(conn, "wearable_offline_minutes", 120)

        fuera = (
            await conn.execute(
                text(
                    """
                    WITH ultimas AS (
                        SELECT DISTINCT ON (vr.patient_id, vr.type)
                               vr.id, vr.patient_id, vr.type, vr.value,
                               vr.measured_at
                        FROM vital_readings vr
                        JOIN patients p ON p.id = vr.patient_id
                        WHERE p.deleted_at IS NULL
                          AND vr.measured_at > now()
                              - make_interval(mins => CAST(:vigencia AS integer))
                        ORDER BY vr.patient_id, vr.type, vr.measured_at DESC
                    )
                    SELECT u.id, u.patient_id, u.type, u.value, u.measured_at,
                           t.min_value, t.max_value,
                           coalesce(vt.label, u.type) AS etiqueta,
                           coalesce(vt.unit, '')      AS unidad
                    FROM ultimas u
                    JOIN vital_thresholds t
                      ON t.patient_id = u.patient_id AND t.type = u.type
                     AND t.deleted_at IS NULL
                    LEFT JOIN vital_types vt ON vt.code = u.type
                    WHERE (t.min_value IS NOT NULL AND u.value < t.min_value)
                       OR (t.max_value IS NOT NULL AND u.value > t.max_value)
                    ORDER BY u.measured_at
                    """
                ),
                {"vigencia": vigencia},
            )
        ).mappings().all()

        for m in fuera:
            bajo = (m["min_value"] is not None
                    and m["value"] < m["min_value"])
            # La clave sale del codigo del catalogo y no de una lista de
            # abreviaturas a mano, que es de las cosas que se desactualizan
            # calladas. Su unico trabajo es agrupar "la misma condicion"
            # para la ventana de deduplicacion.
            clave = f"{m['type']}_{'low' if bajo else 'high'}"

            reciente = (
                await conn.execute(
                    text(
                        """
                        SELECT 1 FROM alerts
                         WHERE patient_id = :pid
                           AND dedup_key = :clave
                           AND created_at > now()
                               - make_interval(mins => CAST(:ventana AS integer))
                         LIMIT 1
                        """
                    ),
                    {"pid": str(m["patient_id"]), "clave": clave,
                     "ventana": ventana},
                )
            ).first()
            if reciente is not None:
                omitidas += 1
                continue

            ya = (
                await conn.execute(
                    text(
                        """
                        SELECT 1 FROM alerts
                         WHERE type = 'vital_out_of_range'
                           AND payload ->> 'reading_id' = CAST(:rid AS text)
                         LIMIT 1
                        """
                    ),
                    {"rid": str(m["id"])},
                )
            ).first()
            if ya is not None:
                continue

            unidad = (" " + m["unidad"]) if m["unidad"] else ""
            limite = m["min_value"] if bajo else m["max_value"]
            # Este texto lo lee la familia, asi que va con sus tildes.
            titulo = (f"{m['etiqueta']} bajo el mínimo" if bajo
                      else f"{m['etiqueta']} sobre el máximo")
            detalle = (
                f"{m['etiqueta']} {_numero(m['value'])}{unidad} "
                f"({'mínimo' if bajo else 'máximo'} configurado "
                f"{_numero(limite)}{unidad})."
            )

            await conn.execute(
                text(
                    """
                    INSERT INTO alerts
                        (patient_id, type, severity, title, detail,
                         payload, dedup_key, status)
                    VALUES
                        (:pid, 'vital_out_of_range', 'warning',
                         :titulo, :detalle,
                         CAST(:payload AS jsonb), :clave, 'active')
                    """
                ),
                {
                    "pid": str(m["patient_id"]),
                    # title es varchar(120): una etiqueta larga del catalogo
                    # no puede reventar el INSERT.
                    "titulo": titulo[:120],
                    "detalle": detalle,
                    "clave": clave,
                    "payload": json.dumps({
                        "reading_id": str(m["id"]),
                        "type": m["type"],
                        "value": float(m["value"]),
                        "min_value": (float(m["min_value"])
                                      if m["min_value"] is not None else None),
                        "max_value": (float(m["max_value"])
                                      if m["max_value"] is not None else None),
                        "measured_at": m["measured_at"].isoformat(),
                    }),
                },
            )
            creadas += 1

    if verbose:
        print(f"alertas de vitales creadas : {creadas}")
        print(f"en espera por la ventana   : {omitidas}")
    return {"creadas": creadas, "en_espera": omitidas}


async def calcular_semaforo(*, verbose: bool = True) -> dict[str, int]:
    """Calcula el semaforo del dia de cada paciente y lo guarda.

    POR QUE HACE FALTA
        caregiver.py lee de wellbeing_snapshots el estado del paciente para
        la pantalla de la cuidadora, y nadie escribia esa tabla. La llenaba
        el seed de desarrollo, con siete dias y un 'ok' fijo para hoy, y
        ahi se detenia: al dia siguiente ya no habia fila nueva y la
        pantalla mostraba el ultimo dia calculado, que es lo que hace el
        router cuando no encuentra el de hoy. En una instalacion sin seed no
        habia ninguna, nunca.

        Las dos salidas son malas por el mismo motivo. Un estado de hace
        tres dias presentado como el de hoy, o un verde que nadie calculo,
        tranquilizan a la familia sin haber mirado nada, y esto es una
        aplicacion de cuidado de adultos mayores.

        La tabla guarda tambien los tres conteos que respaldan el estado,
        "para auditar como se llego al estado", dice su propio comentario.
        Se llenan: un rojo sin numeros detras no se puede defender frente a
        una familia que pregunta por que.

    LA MISMA REGLA, A PROPOSITO
        El calculo es el de _compute_wellbeing en vitals.py, incluido el
        texto de los motivos:

            attention : una alerta critical activa, o un vital fuera de rango
            warning   : una alerta warning activa, o dosis omitidas hoy
            ok        : ninguno de los anteriores

        La duplicacion es deliberada y conviene decir por que. El endpoint
        del semaforo calcula en vivo cada vez que alguien abre la pantalla;
        esta tabla es la fotografia del dia, que es lo que permite mirar la
        semana hacia atras. Son dos cosas distintas, pero la regla tiene
        que ser una sola: si se separan, la cuidadora ve un estado y la
        familia ve otro para el mismo dia.

    LA FECHA
        El dia es el dia chileno, igual que las dosis. OJO: vitals.py cuenta
        las dosis de hoy con current_date, que es la fecha de la zona de la
        sesion de Postgres, y el contenedor corre en UTC. Desde las nueve de
        la noche en Chile, para ese endpoint ya es manana. Aca se usa la
        hora local a proposito; dejar de lado ese desfase en el endpoint es
        una decision aparte, no de este proceso.

    No se filtra por antiguedad de la medicion, igual que la pantalla: la
    ultima medicion conocida es el ultimo estado conocido. La alerta si
    tiene limite de antiguedad, y la diferencia es sana: una alerta es un
    aviso, que tiene momento; el semaforo es un estado, que dura hasta que
    llegue otro dato.
    """
    pacientes = 0
    por_estado: dict[str, int] = {"ok": 0, "warning": 0, "attention": 0}

    async with engine.begin() as conn:
        ids = (
            await conn.execute(
                text("SELECT id FROM patients WHERE deleted_at IS NULL "
                     "ORDER BY full_name")
            )
        ).scalars().all()

        for pid in ids:
            pid = str(pid)
            pacientes += 1

            # Alertas activas, lo mas nuevo arriba, igual que _active_alerts.
            alertas = (
                await conn.execute(
                    text(
                        """
                        SELECT severity, title
                        FROM alerts
                        WHERE patient_id = :pid AND status = 'active'
                        ORDER BY created_at DESC
                        """
                    ),
                    {"pid": pid},
                )
            ).mappings().all()

            # Ultima medicion de cada tipo contra su umbral, igual que
            # _latest_items: sin limite de antiguedad y comparando solo los
            # tipos que tienen umbral.
            fuera = (
                await conn.execute(
                    text(
                        """
                        WITH ultimas AS (
                            SELECT DISTINCT ON (type) type, value
                            FROM vital_readings
                            WHERE patient_id = :pid
                            ORDER BY type, measured_at DESC
                        )
                        SELECT u.type, u.value, coalesce(vt.unit, '') AS unidad
                        FROM ultimas u
                        JOIN vital_thresholds t
                          ON t.patient_id = :pid AND t.type = u.type
                         AND t.deleted_at IS NULL
                        LEFT JOIN vital_types vt ON vt.code = u.type
                        WHERE (t.min_value IS NOT NULL AND u.value < t.min_value)
                           OR (t.max_value IS NOT NULL AND u.value > t.max_value)
                        ORDER BY u.type
                        """
                    ),
                    {"pid": pid},
                )
            ).mappings().all()

            omitidas = (
                await conn.execute(
                    text(
                        """
                        SELECT count(*)
                        FROM scheduled_doses sd
                        JOIN medications m ON m.id = sd.medication_id
                        WHERE m.patient_id = :pid
                          AND sd.status = 'missed'
                          AND CAST(sd.scheduled_at AT TIME ZONE CAST(:zona AS text)
                                   AS date)
                              = CAST(now() AT TIME ZONE CAST(:zona AS text) AS date)
                        """
                    ),
                    {"pid": pid, "zona": ZONA},
                )
            ).scalar() or 0

            criticas = [a for a in alertas if a["severity"] == "critical"]
            avisos   = [a for a in alertas if a["severity"] == "warning"]

            # El mismo orden y el mismo texto que _compute_wellbeing.
            motivos = [f"Alerta crítica activa: {a['title']}" for a in criticas]
            motivos += [
                f"{v['type']} fuera de rango ({float(v['value'])} {v['unidad']})"
                for v in fuera
            ]
            estado = "attention" if (criticas or fuera) else "ok"
            motivos += [f"Alerta activa: {a['title']}" for a in avisos]
            if omitidas > 0:
                motivos.append(f"{omitidas} dosis omitida(s) hoy")
            if estado != "attention" and (avisos or omitidas > 0):
                estado = "warning"

            await conn.execute(
                text(
                    """
                    INSERT INTO wellbeing_snapshots
                        (patient_id, snapshot_date, status, reasons,
                         vitals_out_of_range, doses_missed, active_alerts)
                    VALUES
                        (:pid,
                         CAST(now() AT TIME ZONE CAST(:zona AS text) AS date),
                         :estado, CAST(:motivos AS jsonb),
                         :fuera, :omitidas, :activas)
                    ON CONFLICT (patient_id, snapshot_date) DO UPDATE
                        SET status = EXCLUDED.status,
                            reasons = EXCLUDED.reasons,
                            vitals_out_of_range = EXCLUDED.vitals_out_of_range,
                            doses_missed = EXCLUDED.doses_missed,
                            active_alerts = EXCLUDED.active_alerts,
                            computed_at = now()
                    """
                ),
                {"pid": pid, "zona": ZONA, "estado": estado,
                 "motivos": json.dumps(motivos, ensure_ascii=False),
                 "fuera": len(fuera), "omitidas": int(omitidas),
                 "activas": len(alertas)},
            )
            por_estado[estado] += 1

    if verbose:
        print(f"pacientes calculados : {pacientes}")
        for e in ("ok", "warning", "attention"):
            print(f"  {e:<10} : {por_estado[e]}")
    return {"pacientes": pacientes, **por_estado}


async def _main(argv: list[str]) -> int:
    tareas = {"barrer-subidas": barrer_subidas_vencidas,
              "generar-dosis": generar_dosis,
              "marcar-vencidas": marcar_dosis_vencidas,
              "alertar-dosis": alertar_dosis_omitidas,
              "alertar-vitales": alertar_vitales_fuera_de_rango,
              "semaforo": calcular_semaforo}
    if len(argv) != 1 or argv[0] not in tareas:
        print(f"uso: python -m app.maintenance <{' | '.join(tareas)}>")
        return 2
    try:
        await tareas[argv[0]]()
    finally:
        await engine.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(_main(sys.argv[1:])))

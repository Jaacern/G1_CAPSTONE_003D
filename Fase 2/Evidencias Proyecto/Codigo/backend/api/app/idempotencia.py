"""Idempotencia de reenvios (RF-81).

La app guarda las acciones que no pudo mandar y las reintenta cuando vuelve la
senal. El problema no es el reintento, es que la app no siempre sabe si el
primer envio llego: la conexion se puede cortar justo despues de que el
servidor guardo la toma y antes de que la respuesta alcanzara a volver. Desde
el telefono ese caso es indistinguible de un envio que nunca salio.

Por eso la decision no se le deja a la app. Cada accion viaja con una clave
propia en la cabecera Idempotency-Key, y el servidor recuerda que respuesta
dio para esa clave. Si la clave vuelve, devuelve la misma respuesta sin
escribir nada.

Se usa en dos lineas dentro del endpoint:

    previa = await idem.previa(db, user_id, SalidaOut)
    if previa is not None:
        return previa
    ... la logica de siempre, que arma `salida` ...
    await idem.guardar(db, user_id, salida, status_code=201)
    await db.commit()
    return salida

El guardar va ANTES del commit a proposito, en la misma transaccion que la
escritura. Asi las dos cosas pasan juntas o no pasa ninguna: no puede quedar
una toma registrada cuya clave no se anoto, que es justo el caso que haria
duplicar al siguiente reintento.

Sin la cabecera todo esto no hace nada y el endpoint se comporta como antes.
Se manda solo desde la cola de la app; una peticion normal de la pantalla no
la necesita, porque ahi la persona ve el resultado y no reintenta a ciegas.
"""

from __future__ import annotations

import json
from typing import TypeVar

from fastapi import Header, Request
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ApiError

M = TypeVar("M", bound=BaseModel)

# Un uuid entra de sobra. El techo esta para que la cabecera no se use como
# deposito de datos.
LARGO_MAXIMO = 80


class Idem:
    """La clave de reenvio de esta peticion, o ninguna."""

    def __init__(self, clave: str | None, metodo: str, ruta: str) -> None:
        self.clave = clave
        self.metodo = metodo
        self.ruta = ruta

    async def previa(
        self, db: AsyncSession, user_id: str, modelo: type[M]
    ) -> M | None:
        """La respuesta que ya se dio para esta clave, si la hubo.

        Devuelve None cuando no viene clave o cuando es la primera vez, que
        son los dos casos en que el endpoint tiene que hacer su trabajo.
        """
        if self.clave is None:
            return None

        fila = (
            await db.execute(
                text(
                    """
                    SELECT method, path, response_body
                      FROM idempotency_keys
                     WHERE user_id = :uid AND idem_key = :clave
                    """
                ),
                {"uid": str(user_id), "clave": self.clave},
            )
        ).mappings().first()
        if fila is None:
            return None

        if fila["method"] != self.metodo or fila["path"] != self.ruta:
            # La misma clave en otra accion. Devolver la respuesta guardada
            # seria peor que fallar: la app creeria que registro una toma
            # cuando lo que se le esta contestando es un mensaje de chat.
            raise ApiError(
                status_code=422,
                code="IDEMPOTENCY_KEY_REUSED",
                message="Esa clave ya se uso para otra accion.",
                details=[{"field": "Idempotency-Key",
                          "message": "Cada accion necesita su propia clave."}],
            )

        cuerpo = fila["response_body"]
        if isinstance(cuerpo, str):  # segun el driver, jsonb llega como texto
            cuerpo = json.loads(cuerpo)
        return modelo.model_validate(cuerpo)

    async def guardar(
        self,
        db: AsyncSession,
        user_id: str,
        salida: BaseModel,
        *,
        status_code: int = 201,
    ) -> None:
        """Anota la respuesta de esta clave, en la transaccion de la escritura.

        Si otro reenvio de la misma clave gano la carrera, el UNIQUE lo corta
        aqui y se cae la transaccion entera, incluida la escritura que esta
        peticion traia. Por eso no duplica: no es que se descarte la segunda
        copia despues, es que nunca llega a existir.
        """
        if self.clave is None:
            return

        try:
            await db.execute(
                text(
                    """
                    INSERT INTO idempotency_keys (
                        user_id, idem_key, method, path, status_code,
                        response_body
                    ) VALUES (
                        :uid, :clave, :metodo, :ruta, :sc,
                        CAST(:cuerpo AS jsonb)
                    )
                    """
                ),
                {
                    "uid": str(user_id),
                    "clave": self.clave,
                    "metodo": self.metodo,
                    "ruta": self.ruta,
                    "sc": status_code,
                    "cuerpo": salida.model_dump_json(),
                },
            )
        except IntegrityError as e:
            # Dos reenvios de la misma accion a la vez. El que pierde no
            # escribe nada y se le pide reintentar: en ese reintento la clave
            # ya estara anotada y se le devolvera la respuesta del primero.
            raise ApiError(
                status_code=409,
                code="RETRY_IN_PROGRESS",
                message="Esa accion se esta registrando en este momento. "
                        "Reintenta en unos segundos.",
            ) from e


def idempotencia(
    request: Request,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
) -> Idem:
    """Dependencia de FastAPI: lee la cabecera y la valida."""
    if idempotency_key is not None:
        idempotency_key = idempotency_key.strip()
        if not idempotency_key or len(idempotency_key) > LARGO_MAXIMO:
            raise ApiError(
                status_code=422,
                code="INVALID_IDEMPOTENCY_KEY",
                message="La clave de reenvio no es valida.",
                details=[{"field": "Idempotency-Key",
                          "message": f"Entre 1 y {LARGO_MAXIMO} caracteres."}],
            )
    return Idem(idempotency_key, request.method, request.url.path)

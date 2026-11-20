"""Proveedor de notificaciones push.

Mismo patron que storage.py, assistant_provider.py, speech_provider.py y
ocr_provider.py. La aplicacion habla con una interfaz y el proveedor concreto
se elige por variable de entorno, asi encender el envio cuando exista el
proyecto de Firebase es configuracion y no un cambio de codigo.

    NotConfigured  la que corre mientras no haya credenciales. No envia y
                   lo dice.
    Fcm            Firebase Cloud Messaging, API HTTP v1.

POR QUE NotConfigured NO FINGE EL ENVIO
    Decir "enviado" sin haber enviado nada es lo peor que puede hacer esto:
    la tabla de entregas mostraria que la familia fue avisada de una caida
    cuando nadie recibio nada. Con el proveedor apagado cada entrega queda
    como fallida, con el motivo escrito, que es la verdad.

POR QUE LA API HTTP Y NO firebase-admin
    El SDK oficial es sincrono y arrastra una docena de dependencias de
    Google. Aca hacen falta dos llamadas HTTP, pedir el token de acceso y
    enviar el mensaje, que httpx ya resuelve, y firmar un JWT con RS256, que
    python-jose ya resuelve. Las dos librerias estaban instaladas.
"""
from __future__ import annotations

import asyncio
import json
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class PushNotConfigured(RuntimeError):
    """El proveedor de push no esta configurado."""


@dataclass
class Envio:
    """Lo que paso con un mensaje.

    token_invalido separa dos fallas que piden cosas distintas. Si el token
    ya no sirve (se desinstalo la aplicacion, se restauro el telefono), hay
    que dejar de usarlo: reintentar es inutil. Si fallo la red o el servicio,
    el token esta bien y vale la pena insistir.
    """
    ok: bool
    token_invalido: bool = False
    error: str | None = None


class PushSettings(BaseSettings):
    # none | fcm
    push_provider: str = "none"
    # La cuenta de servicio de Firebase, la que se descarga como JSON desde
    # la consola. Una de las dos: la ruta al archivo, o el contenido entero
    # en una variable, que es mas comodo como secreto del contenedor.
    fcm_credentials_file: str = ""
    fcm_credentials_json: str = ""
    push_timeout_seconds: int = 10

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )


@lru_cache
def get_push_settings() -> PushSettings:
    return PushSettings()


class PushProvider(ABC):
    @property
    @abstractmethod
    def disponible(self) -> bool: ...

    @abstractmethod
    async def enviar(self, *, token: str, titulo: str, cuerpo: str,
                     datos: dict[str, str], canal: str = "alerts",
                     critica: bool = False) -> Envio:
        """Envia una notificacion a un aparato.

        [datos] viaja junto al mensaje y es lo que la aplicacion lee al
        tocar la notificacion. Solo cadenas: FCM rechaza cualquier otro tipo.

        [canal] es el canal de Android que define sonido y prioridad en el
        telefono. La aplicacion ya los tiene creados: 'falls', 'alerts',
        'meds' y 'general'.

        Nunca lanza por una falla de envio: la devuelve en el resultado,
        porque quien llama esta recorriendo una lista de aparatos y la falla
        de uno no puede cortar el aviso a los demas.
        """


class NotConfigured(PushProvider):
    @property
    def disponible(self) -> bool:
        return False

    async def enviar(self, **_) -> Envio:
        return Envio(ok=False,
                     error="El envio de push no esta configurado en este servidor.")


class Fcm(PushProvider):
    """Firebase Cloud Messaging por su API HTTP v1.

    Dos pasos. Primero se cambia un JWT firmado con la llave de la cuenta de
    servicio por un token de acceso de Google, que dura una hora y se guarda
    hasta poco antes de vencer. Despues cada mensaje es un POST con ese token.
    """

    _SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
    _TOKEN_URL = "https://oauth2.googleapis.com/token"

    def __init__(self, cfg: PushSettings):
        crudo = cfg.fcm_credentials_json.strip()
        if not crudo and cfg.fcm_credentials_file:
            try:
                with open(cfg.fcm_credentials_file, encoding="utf-8") as f:
                    crudo = f.read()
            except OSError as e:
                raise RuntimeError(
                    f"PUSH_PROVIDER=fcm pero no se pudo leer "
                    f"FCM_CREDENTIALS_FILE ({e})."
                ) from e
        if not crudo:
            raise RuntimeError(
                "PUSH_PROVIDER=fcm pero faltan FCM_CREDENTIALS_FILE o "
                "FCM_CREDENTIALS_JSON. Mientras no exista el proyecto de "
                "Firebase, deja PUSH_PROVIDER=none."
            )
        try:
            cuenta = json.loads(crudo)
            self._proyecto = cuenta["project_id"]
            self._correo = cuenta["client_email"]
            self._llave = cuenta["private_key"]
        except (ValueError, KeyError) as e:
            raise RuntimeError(
                "Las credenciales de FCM no son el JSON de una cuenta de "
                "servicio: faltan project_id, client_email o private_key."
            ) from e
        self.cfg = cfg
        self._acceso: str | None = None
        self._vence = 0.0
        self._candado = asyncio.Lock()

    @property
    def disponible(self) -> bool:
        return True

    async def _token_de_acceso(self, cliente) -> str:
        # El candado evita que diez envios simultaneos pidan diez tokens.
        async with self._candado:
            if self._acceso and time.time() < self._vence - 60:
                return self._acceso
            from jose import jwt

            ahora = int(time.time())
            firmado = jwt.encode(
                {"iss": self._correo, "scope": self._SCOPE,
                 "aud": self._TOKEN_URL, "iat": ahora, "exp": ahora + 3600},
                self._llave, algorithm="RS256",
            )
            r = await cliente.post(self._TOKEN_URL, data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": firmado,
            })
            r.raise_for_status()
            d = r.json()
            self._acceso = d["access_token"]
            self._vence = time.time() + int(d.get("expires_in", 3600))
            return self._acceso

    def _mensaje(self, *, token: str, titulo: str, cuerpo: str,
                 datos: dict[str, str], canal: str, critica: bool) -> dict:
        return {"message": {
            "token": token,
            "notification": {"title": titulo, "body": cuerpo},
            "data": {k: str(v) for k, v in datos.items()},
            "android": {
                # Sin prioridad alta Android puede retener el mensaje hasta
                # que el telefono salga del reposo, que es justo cuando una
                # alerta no puede esperar.
                "priority": "HIGH",
                "notification": {"channel_id": canal},
            },
            "apns": {
                "headers": {"apns-priority": "10"},
                "payload": {"aps": {
                    "sound": "default",
                    # time-sensitive atraviesa el modo de concentracion sin
                    # necesitar el permiso especial que exige 'critical'.
                    "interruption-level":
                        "time-sensitive" if critica else "active",
                }},
            },
        }}

    async def enviar(self, *, token: str, titulo: str, cuerpo: str,
                     datos: dict[str, str], canal: str = "alerts",
                     critica: bool = False) -> Envio:
        import httpx

        try:
            async with httpx.AsyncClient(
                    timeout=self.cfg.push_timeout_seconds) as c:
                acceso = await self._token_de_acceso(c)
                r = await c.post(
                    f"https://fcm.googleapis.com/v1/projects/"
                    f"{self._proyecto}/messages:send",
                    headers={"Authorization": f"Bearer {acceso}"},
                    json=self._mensaje(token=token, titulo=titulo,
                                       cuerpo=cuerpo, datos=datos,
                                       canal=canal, critica=critica),
                )
        except Exception as e:  # noqa: BLE001
            return Envio(ok=False, error=f"No se pudo contactar a FCM: "
                                         f"{str(e).splitlines()[0]}"[:300])

        if r.status_code == 200:
            return Envio(ok=True)
        return _leer_error(r.status_code, r.text)


def _leer_error(codigo: int, cuerpo: str) -> Envio:
    """Traduce la respuesta de error de FCM.

    FCM avisa que un token murio de dos formas: 404 con UNREGISTERED cuando
    la aplicacion se desinstalo, y 400 con INVALID_ARGUMENT cuando el token
    esta mal formado. Las dos significan lo mismo para nosotros: ese aparato
    no va a recibir nada nunca mas con ese token.

    Un 400 tambien puede ser un mensaje mal armado de nuestro lado. Se
    distingue mirando si el error nombra el token: si no lo nombra, el token
    se conserva, porque apagarle las notificaciones a alguien por un error
    nuestro seria castigar a quien no hizo nada.
    """
    estado = ""
    detalle = cuerpo[:200]
    try:
        err = json.loads(cuerpo).get("error", {})
        estado = err.get("status", "")
        detalle = err.get("message", detalle)
        for d in err.get("details", []):
            estado = d.get("errorCode", estado)
    except (ValueError, AttributeError):
        pass
    muerto = estado == "UNREGISTERED" or codigo == 404 or (
        estado == "INVALID_ARGUMENT" and "token" in detalle.lower())
    return Envio(ok=False, token_invalido=muerto,
                 error=f"FCM {codigo} {estado}: {detalle}"[:300])


@lru_cache
def get_push() -> PushProvider:
    cfg = get_push_settings()
    if cfg.push_provider.lower() == "fcm":
        return Fcm(cfg)
    return NotConfigured()

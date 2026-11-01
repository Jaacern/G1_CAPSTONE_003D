"""Proveedor de voz: transcribir audio y leer texto en voz alta.

Mismo patron que storage.py y assistant_provider.py. La aplicacion habla
con una interfaz y el proveedor concreto se elige por variable de entorno,
asi conectar Azure AI Speech cuando Alloxentric entregue las credenciales
es configuracion y no un cambio de codigo.

    NotConfigured  la que corre hoy. Devuelve un error claro.
    AzureSpeech    la de produccion.

Por que NotConfigured no devuelve un texto de relleno: en STT, inventar la
transcripcion de una nota de voz que una cuidadora dejo sobre un paciente
es peor que no transcribirla. La pantalla puede mostrar la nota sin texto
y que la persona la escuche, pero no puede mostrar un texto que nadie
dijo.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class SpeechNotConfigured(RuntimeError):
    """El proveedor de voz no esta configurado."""


class SpeechSettings(BaseSettings):
    # none | azure
    speech_provider: str = "none"
    speech_region:   str = ""
    speech_api_key:  str = ""
    # Voz por defecto. La pantalla manda es-MX-DaliaNeural, pero el valor
    # vive aca para poder cambiarlo sin tocar la aplicacion.
    speech_default_voice: str = "es-CL-CatalinaNeural"
    speech_timeout_seconds: int = 30

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )


@lru_cache
def get_speech_settings() -> SpeechSettings:
    return SpeechSettings()


class SpeechProvider(ABC):
    @property
    @abstractmethod
    def disponible(self) -> bool: ...

    @abstractmethod
    async def transcribir(self, *, audio: bytes, mime_type: str) -> str:
        """Devuelve el texto de un audio."""

    @abstractmethod
    async def sintetizar(self, *, texto: str, voz: str) -> bytes:
        """Devuelve el audio de un texto, en mp3."""


class NotConfigured(SpeechProvider):
    @property
    def disponible(self) -> bool:
        return False

    async def transcribir(self, **_) -> str:
        raise SpeechNotConfigured("El servicio de voz no esta conectado.")

    async def sintetizar(self, **_) -> bytes:
        raise SpeechNotConfigured("El servicio de voz no esta conectado.")


class AzureSpeech(SpeechProvider):
    """Azure AI Speech por su API REST.

    Se usa REST y no el SDK a proposito: el SDK de Speech es sincrono y
    pesado, y aca solo hacen falta dos llamadas HTTP que httpx, que ya
    esta instalado, resuelve sin agregar dependencias.
    """

    def __init__(self, cfg: SpeechSettings):
        if not cfg.speech_region or not cfg.speech_api_key:
            raise RuntimeError(
                "SPEECH_PROVIDER=azure pero faltan SPEECH_REGION o "
                "SPEECH_API_KEY. Mientras Alloxentric no entregue las "
                "credenciales, deja SPEECH_PROVIDER=none."
            )
        self.cfg = cfg

    @property
    def disponible(self) -> bool:
        return True

    async def transcribir(self, *, audio: bytes, mime_type: str) -> str:
        import httpx

        url = (f"https://{self.cfg.speech_region}.stt.speech.microsoft.com"
               f"/speech/recognition/conversation/cognitiveservices/v1")
        async with httpx.AsyncClient(timeout=self.cfg.speech_timeout_seconds) as c:
            r = await c.post(
                url,
                params={"language": "es-CL", "format": "simple"},
                headers={
                    "Ocp-Apim-Subscription-Key": self.cfg.speech_api_key,
                    "Content-Type": mime_type,
                },
                content=audio,
            )
            r.raise_for_status()
            datos = r.json()

        # Azure devuelve RecognitionStatus. Un audio en silencio responde
        # 200 con status NoMatch, que no es un error del sistema: es que
        # no se escucho nada, y eso se devuelve como texto vacio.
        if datos.get("RecognitionStatus") != "Success":
            return ""
        return datos.get("DisplayText", "")

    async def sintetizar(self, *, texto: str, voz: str) -> bytes:
        import html

        import httpx

        url = (f"https://{self.cfg.speech_region}.tts.speech.microsoft.com"
               f"/cognitiveservices/v1")
        # El texto va escapado: un apellido con & o una comilla romperian
        # el XML y Azure devolveria un error que no dice nada.
        ssml = (
            f'<speak version="1.0" xml:lang="es-CL">'
            f'<voice name="{voz}">{html.escape(texto)}</voice></speak>'
        )
        async with httpx.AsyncClient(timeout=self.cfg.speech_timeout_seconds) as c:
            r = await c.post(
                url,
                headers={
                    "Ocp-Apim-Subscription-Key": self.cfg.speech_api_key,
                    "Content-Type": "application/ssml+xml",
                    # Formato que el reproductor de la aplicacion entiende.
                    "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
                },
                content=ssml.encode("utf-8"),
            )
            r.raise_for_status()
            return r.content


@lru_cache
def get_speech() -> SpeechProvider:
    cfg = get_speech_settings()
    if cfg.speech_provider == "azure":
        return AzureSpeech(cfg)
    return NotConfigured()

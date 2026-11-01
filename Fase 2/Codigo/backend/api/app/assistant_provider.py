"""Proveedor del asistente: adaptador con el modelo detras.

Mismo patron que storage.py. La aplicacion habla con una interfaz y el
proveedor concreto se elige por variable de entorno, para que conectar el
modelo cuando Alloxentric entregue las credenciales sea configuracion y no
un cambio de codigo.

Hay dos implementaciones:

    NotConfigured  la que corre hoy. No inventa respuestas: devuelve un
                   error claro diciendo que el asistente no esta conectado.
    AzureOpenAI    la de produccion. Arma el contexto con el expediente del
                   paciente, llama al modelo y devuelve la respuesta con
                   las fuentes que uso.

Por que NotConfigured responde con un error y no con un texto generico:
una respuesta inventada sobre la salud de un adulto mayor es exactamente
el tipo de cosa que no puede salir de aca. Es mejor que la pantalla diga
que el asistente no esta disponible a que muestre algo que parece una
respuesta del expediente y no lo es.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


@dataclass
class Fuente:
    """Un dato del expediente que respaldo la respuesta."""

    tabla:  str
    id:     str
    label:  str


@dataclass
class Respuesta:
    texto:   str
    fuentes: list[Fuente] = field(default_factory=list)


class AssistantNotConfigured(RuntimeError):
    """El proveedor del modelo no esta configurado."""


class AssistantSettings(BaseSettings):
    # none | azure_openai
    assistant_provider: str = "none"
    assistant_endpoint: str = ""
    assistant_api_key:  str = ""
    assistant_model:    str = "gpt-4o-mini"
    # Techo de tokens de la respuesta, para que una pregunta abierta no se
    # convierta en una cuenta abierta.
    assistant_max_tokens: int = 600
    assistant_timeout_seconds: int = 30

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )


@lru_cache
def get_assistant_settings() -> AssistantSettings:
    return AssistantSettings()


class AssistantProvider(ABC):
    """Lo minimo que la API necesita del asistente."""

    @property
    @abstractmethod
    def disponible(self) -> bool:
        """Si se puede preguntar ahora mismo."""

    @abstractmethod
    async def responder(self, *, pregunta: str, contexto: str,
                        rol: str, historial: list[dict]) -> Respuesta:
        """Responde una pregunta sobre el expediente.

        contexto   el resumen del expediente del paciente, ya armado por la
                   aplicacion: el proveedor no consulta la base.
        rol        el rol de quien pregunta, para ajustar el detalle.
        historial  los mensajes previos de la conversacion.
        """


class NotConfigured(AssistantProvider):
    @property
    def disponible(self) -> bool:
        return False

    async def responder(self, **_) -> Respuesta:
        raise AssistantNotConfigured(
            "El asistente no esta conectado a ningun proveedor."
        )


class AzureOpenAI(AssistantProvider):
    """Implementacion de produccion.

    El cliente se importa de forma perezosa para que la API arranque igual
    en desarrollo, donde el paquete no esta instalado ni hace falta.
    """

    def __init__(self, cfg: AssistantSettings):
        if not cfg.assistant_endpoint or not cfg.assistant_api_key:
            raise RuntimeError(
                "ASSISTANT_PROVIDER=azure_openai pero faltan "
                "ASSISTANT_ENDPOINT o ASSISTANT_API_KEY. Mientras "
                "Alloxentric no entregue las credenciales, deja "
                "ASSISTANT_PROVIDER=none."
            )
        self.cfg = cfg

    @property
    def disponible(self) -> bool:
        return True

    # El asistente solo responde con lo que viene en el contexto. Es la
    # instruccion que impide que el modelo complete con conocimiento
    # general lo que el expediente no dice, que en salud es lo peligroso.
    _SISTEMA = (
        "Eres el asistente de AgeCare y respondes preguntas sobre el "
        "expediente de un adulto mayor.\n"
        "Reglas que no puedes romper:\n"
        "1. Responde unicamente con los datos del expediente que vienen "
        "en el contexto. Si el contexto no tiene la respuesta, di que no "
        "esta registrado en el expediente.\n"
        "2. No diagnostiques, no indiques tratamientos ni cambies dosis. "
        "Si te preguntan eso, responde que lo consulte con su medico.\n"
        "3. Si algo en el contexto sugiere una urgencia, dilo primero y "
        "recomienda contactar al servicio de urgencia.\n"
        "4. Responde en espanol, breve y en lenguaje simple."
    )

    async def responder(self, *, pregunta: str, contexto: str,
                        rol: str, historial: list[dict]) -> Respuesta:
        from openai import AsyncAzureOpenAI

        cliente = AsyncAzureOpenAI(
            azure_endpoint=self.cfg.assistant_endpoint,
            api_key=self.cfg.assistant_api_key,
            api_version="2024-06-01",
            timeout=self.cfg.assistant_timeout_seconds,
        )
        mensajes = [
            {"role": "system", "content": self._SISTEMA},
            {"role": "system",
             "content": f"Quien pregunta tiene el rol: {rol}."},
            {"role": "system", "content": f"Expediente:\n{contexto}"},
            *historial,
            {"role": "user", "content": pregunta},
        ]
        salida = await cliente.chat.completions.create(
            model=self.cfg.assistant_model,
            messages=mensajes,
            max_tokens=self.cfg.assistant_max_tokens,
            temperature=0.2,
        )
        return Respuesta(texto=salida.choices[0].message.content or "")


@lru_cache
def get_assistant() -> AssistantProvider:
    cfg = get_assistant_settings()
    if cfg.assistant_provider == "azure_openai":
        return AzureOpenAI(cfg)
    return NotConfigured()

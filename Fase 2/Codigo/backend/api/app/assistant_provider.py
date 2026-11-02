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
    # none | azure_openai | openai_compatible (alias: nvidia)
    assistant_provider: str = "none"
    assistant_endpoint: str = ""
    assistant_api_key:  str = ""
    assistant_model:    str = "gpt-4o-mini"
    # Base URL de un proveedor con API compatible con OpenAI. La usa el
    # proveedor 'openai_compatible': NVIDIA, Anthropic (Claude), Groq, etc.
    assistant_base_url: str = "https://integrate.api.nvidia.com/v1"
    # Algunos modelos (p. ej. Claude Haiku 5.5) rechazan temperature/top_p
    # con un 400. Con false no se mandan y el modelo usa sus valores.
    assistant_send_sampling: bool = True
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


import re

# Bloque de razonamiento que los modelos tipo DeepSeek embeben en el
# contenido. No es parte de la respuesta y no puede llegar a la familia:
# ahi el modelo "piensa en voz alta" y puede barajar hipotesis que no son
# conclusiones.
_RAZONAMIENTO = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def _solo_respuesta_final(mensaje) -> str:
    """Devuelve la respuesta del modelo sin su razonamiento interno.

    DeepSeek expone el razonamiento de dos maneras segun el despliegue: en
    un campo aparte (reasoning_content), o dentro del texto entre <think> y
    </think>. En ambos casos se descarta: a quien cuida al paciente solo le
    sirve la conclusion, no el camino que el modelo siguio para llegar.
    """
    texto = (getattr(mensaje, "content", None) or "")
    # Por si el modelo abrio <think> y el corte por tokens dejo el bloque
    # sin cerrar: nos quedamos con lo que venga despues de un </think>
    # suelto, y si solo hay apertura, con nada antes de ella.
    texto = _RAZONAMIENTO.sub("", texto)
    if "</think>" in texto:
        texto = texto.rsplit("</think>", 1)[1]
    elif "<think>" in texto:
        texto = texto.split("<think>", 1)[0]
    return _sin_markdown(texto.strip())


# Negrita/cursiva (**x**, __x__, *x*, _x_) que algunos modelos ponen pese a
# pedir texto plano. La app lo muestra crudo, asi que los asteriscos se ven.
_ENFASIS = re.compile(r"(\*\*|__|\*|_)(.+?)\1", re.DOTALL)


def _sin_markdown(texto: str) -> str:
    """Quita el formato Markdown que se ve feo en la app.

    Es una red de seguridad: la instruccion del prompt ya pide texto plano,
    pero si el modelo igual marca una dosis con **...**, aqui se limpia.
    """
    # Repetir para casos anidados tipo **_x_**.
    for _ in range(3):
        nuevo = _ENFASIS.sub(r"\2", texto)
        if nuevo == texto:
            break
        texto = nuevo
    lineas = []
    for ln in texto.split("\n"):
        s = ln.lstrip()
        # Vinetas "- ", "* ", "+ " al inicio -> fuera el simbolo.
        if s[:2] in ("- ", "* ", "+ "):
            s = s[2:]
        # Encabezados "## ..." -> solo el texto.
        s = s.lstrip("#").lstrip()
        lineas.append(s)
    return "\n".join(lineas).strip()


class NvidiaDeepSeek(AssistantProvider):
    """Asistente servido por NVIDIA (DeepSeek u otro modelo del catalogo).

    NVIDIA expone su catalogo con una API compatible con la de OpenAI, asi
    que se usa el mismo cliente pero apuntando a su endpoint. Solo cambia
    de donde salen las credenciales y la base_url; las reglas clinicas que
    gobiernan la respuesta son las mismas que las de Azure, porque el
    peligro de inventar sobre la salud de un paciente no depende del modelo.

    El cliente se importa de forma perezosa, igual que en Azure, para que
    la API arranque aunque el paquete no este instalado en el entorno.
    """

    # Prompt propio, mas estricto que el de Azure. DeepSeek es un modelo de
    # razonamiento potente y, si se lo deja, completa huecos con su
    # conocimiento general: justo lo que no puede pasar con la salud de un
    # paciente. Estas reglas lo atan al expediente y le prohiben inventar.
    _SISTEMA = (
        "Eres el asistente de AgeCare. Ayudas a la familia y a quienes "
        "cuidan a un adulto mayor a entender lo que ya esta registrado en "
        "su expediente (bitacora, medicamentos, mediciones, alertas, "
        "condiciones). No eres un medico ni reemplazas uno.\n"
        "\n"
        "REGLAS QUE NO PUEDES ROMPER:\n"
        "1. Usa SOLO los datos del bloque 'Expediente'. Esa es tu unica "
        "fuente de verdad. Esta terminantemente prohibido usar tu "
        "conocimiento general de medicina para agregar, suponer o "
        "completar datos que el expediente no contiene.\n"
        "2. No inventes. No agregues nombres, fechas, dosis, diagnosticos "
        "ni valores que no esten escritos literalmente en el expediente. "
        "Si un dato no aparece, es porque no esta registrado.\n"
        "3. Si la respuesta no esta en el expediente, dilo con claridad: "
        "'Eso no esta registrado en el expediente.' No ofrezcas una "
        "respuesta aproximada ni general en su lugar.\n"
        "4. No diagnostiques, no interpretes sintomas, no indiques ni "
        "cambies tratamientos o dosis. Ante una pregunta asi, responde que "
        "debe consultarlo con su medico tratante.\n"
        "5. Si el expediente muestra algo que sugiere una urgencia (una "
        "alerta critica, un valor fuera de rango marcado como grave), "
        "dilo al principio y recomienda contactar al servicio de "
        "urgencias o al medico.\n"
        "6. Cuando cites un dato, se fiel al expediente: repite el valor y "
        "la fecha tal como aparecen, sin redondear ni reinterpretar.\n"
        "7. Responde en espanol de Chile, breve, claro y en lenguaje "
        "simple, sin jerga medica. No muestres tu razonamiento interno; "
        "entrega solo la respuesta final.\n"
        "8. Escribe en texto plano. No uses Markdown: nada de asteriscos "
        "para negrita o cursiva, ni ## titulos, ni vinetas con guion o "
        "asterisco. Si enumeras, usa frases separadas por punto. La app "
        "muestra el texto tal cual, los simbolos de formato se ven feos.\n"
        "9. Puedes terminar tu respuesta con un emoji de corazon para dar "
        "calidez al cuidado, pero con mesura: uno al cierre, no en cada "
        "frase, y nunca cuando informes una urgencia o algo delicado.\n"
        "10. Los signos vitales del reloj se miden muchas veces al dia, asi "
        "que varian entre lectura y lectura; eso es normal, no una "
        "contradiccion. Si el contexto trae un promedio y un rango de 24h, "
        "usalos: da el ultimo valor y, cuando ayude, menciona el rango del "
        "dia. Nunca te disculpes por que las mediciones sean distintas.\n"
    )

    def __init__(self, cfg: AssistantSettings):
        if not cfg.assistant_api_key:
            raise RuntimeError(
                "ASSISTANT_PROVIDER=nvidia pero falta ASSISTANT_API_KEY. "
                "Pon tu API key de NVIDIA (build.nvidia.com) en el .env o "
                "deja ASSISTANT_PROVIDER=none."
            )
        if not cfg.assistant_base_url:
            raise RuntimeError(
                "ASSISTANT_PROVIDER=nvidia pero falta ASSISTANT_BASE_URL."
            )
        self.cfg = cfg

    @property
    def disponible(self) -> bool:
        return True

    # Respuesta fija cuando el expediente no trae nada util. Evita la
    # llamada al modelo con un contexto vacio, que es la situacion que mas
    # invita a alucinar: sin datos, el modelo tiende a rellenar.
    _SIN_CONTEXTO = (
        "No hay informacion registrada en el expediente para responder "
        "esa pregunta. Agrega datos en la bitacora, los medicamentos o "
        "las mediciones, o consulta con el medico tratante."
    )

    async def responder(self, *, pregunta: str, contexto: str,
                        rol: str, historial: list[dict]) -> Respuesta:
        from openai import AsyncOpenAI

        # Sin expediente no se le pregunta al modelo. No es una falla: es la
        # respuesta correcta, y ademas cierra la puerta a que invente.
        if not contexto or not contexto.strip():
            return Respuesta(texto=self._SIN_CONTEXTO)

        cliente = AsyncOpenAI(
            base_url=self.cfg.assistant_base_url,
            api_key=self.cfg.assistant_api_key,
            timeout=self.cfg.assistant_timeout_seconds,
        )
        mensajes = [
            {"role": "system", "content": self._SISTEMA},
            {"role": "system",
             "content": f"Quien pregunta tiene el rol: {rol}."},
            {"role": "system",
             "content": (
                 "A continuacion viene el expediente. Es tu unica fuente. "
                 "Todo lo que afirmes debe poder leerse en el. Si la "
                 "pregunta pide algo que no esta aqui, responde que no "
                 "esta registrado en el expediente.\n\n"
                 f"=== EXPEDIENTE ===\n{contexto}\n=== FIN DEL EXPEDIENTE ==="
             )},
            *historial,
            {"role": "user", "content": pregunta},
        ]
        extra = {}
        if self.cfg.assistant_send_sampling:
            # Lo mas determinista posible: en salud no queremos variedad
            # creativa, queremos que repita lo que dice el expediente.
            extra = {"temperature": 0.1, "top_p": 0.9}
        salida = await cliente.chat.completions.create(
            model=self.cfg.assistant_model,
            messages=mensajes,
            max_tokens=self.cfg.assistant_max_tokens,
            **extra,
        )
        mensaje = salida.choices[0].message
        texto = _solo_respuesta_final(mensaje)
        return Respuesta(texto=texto or self._SIN_CONTEXTO)


@lru_cache
def get_assistant() -> AssistantProvider:
    cfg = get_assistant_settings()
    if cfg.assistant_provider == "azure_openai":
        return AzureOpenAI(cfg)
    if cfg.assistant_provider in ("openai_compatible", "nvidia", "anthropic"):
        return NvidiaDeepSeek(cfg)
    return NotConfigured()

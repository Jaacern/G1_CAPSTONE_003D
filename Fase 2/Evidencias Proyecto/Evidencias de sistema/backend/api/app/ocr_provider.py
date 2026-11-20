"""Proveedor de OCR: sacar el texto de una imagen o un PDF.

Mismo patron que storage.py, assistant_provider.py y speech_provider.py. La
aplicacion habla con una interfaz y el proveedor concreto se elige por
variable de entorno, asi que cambiar de motor es configuracion y no un
cambio de codigo.

    NotConfigured  cuando OCR_PROVIDER viene en 'none'. Devuelve un error
                   claro que la pantalla sabe distinguir.
    NemotronParse Nemotron 3.5 Parse de NVIDIA. La imagen se regenera antes
                   de salir y el texto se sanea al volver.
    Tesseract      la que corre hoy. Gratis y dentro del servidor, asi que
                   la foto de una receta no sale a ninguna parte.

POR QUE NotConfigured NO DEVUELVE UN TEXTO DE RELLENO
    El mismo criterio que la voz. De este texto salen las indicaciones de
    medicamentos de un adulto mayor: devolver algo inventado, o parcial sin
    avisar, es peor que devolver un error.

LO QUE ESTE MODULO NO HACE
    No interpreta. Devuelve el texto tal como lo leyo, con sus errores. Quien
    quiera entender ese texto lo hace aparte, y en el caso de las recetas
    siempre contra los ojos de un medico que confirma antes de guardar.
"""
from __future__ import annotations

import asyncio
import json
import re
import unicodedata
from abc import ABC, abstractmethod
from dataclasses import dataclass
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class OcrNotConfigured(RuntimeError):
    """El proveedor de OCR no esta configurado."""


class OcrFallo(RuntimeError):
    """El motor corrio pero no pudo con el archivo."""


@dataclass
class TextoExtraido:
    texto: str
    motor: str
    idioma: str
    # Confianza media de 0 a 100. Nula cuando el motor no la reporta, que no
    # es lo mismo que cero.
    confianza: float | None = None

    @property
    def caracteres(self) -> int:
        return len(self.texto)

    @property
    def vacio(self) -> bool:
        """Si no salio nada aprovechable.

        Pasa seguido y no es un error: una foto borrosa, un manuscrito, o una
        imagen que no tiene texto. La pantalla tiene que poder decirlo sin
        tratarlo como una falla del sistema.
        """
        return len(self.texto.strip()) < 3


class OcrSettings(BaseSettings):
    # none | tesseract | nvidia_parse
    ocr_provider: str = "none"

    # Idiomas que le pasa a tesseract, en su notacion. 'spa+eng' porque una
    # receta chilena mezcla castellano con nombres de farmacos y unidades en
    # ingles, y pedir los dos cuesta poco.
    ocr_idiomas: str = "spa+eng"

    # Techo de tiempo. Una imagen grande y torcida puede tener a tesseract
    # minutos, y la peticion de una pantalla no puede quedarse esperando.
    ocr_timeout_seconds: int = 45

    # Techo de tamano en megas. Por encima se rechaza antes de procesar: el
    # CHECK de files ya permite hasta 25 MB y una foto de 25 MB de una receta
    # no aporta mas texto que una de 3.
    ocr_max_mb: int = 12

    # --- Proveedor 'nvidia_parse' (Nemotron 3.5 Parse) ---
    # Sin OCR_API_KEY se usa ASSISTANT_API_KEY, que ya es una clave de NVIDIA.
    ocr_api_key: str = ""
    assistant_api_key: str = ""
    ocr_max_tokens: int = 2048
    ocr_parse_url: str = (
        "https://ai.api.nvidia.com/v1/retrieval/nvidia/nemotron-3.5-parse/parse"
    )

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )


@lru_cache
def get_ocr_settings() -> OcrSettings:
    return OcrSettings()


class OcrProvider(ABC):
    @property
    @abstractmethod
    def disponible(self) -> bool: ...

    @abstractmethod
    async def extraer(self, *, contenido: bytes, mime_type: str) -> TextoExtraido:
        """Devuelve el texto de una imagen o un PDF."""


class NotConfigured(OcrProvider):
    @property
    def disponible(self) -> bool:
        return False

    async def extraer(self, **_) -> TextoExtraido:
        raise OcrNotConfigured("El servicio de lectura de imagenes no esta conectado.")


class Tesseract(OcrProvider):
    """OCR local con tesseract.

    Corre dentro del contenedor de la API, asi que la imagen no sale del
    servidor. Lee bien lo impreso; con lo manuscrito no hay que esperar
    mucho, y para eso esta pensado el cambio de proveedor.

    Tesseract es sincrono y usa CPU, asi que se llama en un hilo aparte para
    no bloquear el bucle de eventos mientras procesa.
    """

    # Lo que puede abrir Pillow de los tipos que admite el CHECK de files.
    IMAGENES = {"image/jpeg", "image/png", "image/webp", "image/heic"}

    def __init__(self, cfg: OcrSettings) -> None:
        self._cfg = cfg

    @property
    def disponible(self) -> bool:
        return True

    async def extraer(self, *, contenido: bytes, mime_type: str) -> TextoExtraido:
        cfg = self._cfg
        if len(contenido) > cfg.ocr_max_mb * 1024 * 1024:
            raise OcrFallo(
                f"El archivo pasa de {cfg.ocr_max_mb} MB y no se puede procesar."
            )
        if mime_type not in self.IMAGENES:
            # El PDF necesita convertirse a imagen primero (poppler), que es
            # otra dependencia del sistema. Se deja fuera a proposito en vez
            # de fallar con un error de libreria que no dice nada.
            raise OcrFallo(
                f"Por ahora solo se leen imagenes, no {mime_type}."
            )

        try:
            return await asyncio.wait_for(
                asyncio.to_thread(self._leer, contenido),
                timeout=cfg.ocr_timeout_seconds,
            )
        except asyncio.TimeoutError as e:
            raise OcrFallo(
                "La lectura tardo demasiado. Prueba con una foto mas chica "
                "o mejor enfocada."
            ) from e

    def _leer(self, contenido: bytes) -> TextoExtraido:
        # Los import van aca dentro para que el modulo se pueda importar
        # aunque tesseract no este instalado: con OCR_PROVIDER en 'none' la
        # aplicacion arranca igual y responde 503, que es lo que hace hoy el
        # asistente sin credenciales.
        import io

        import pytesseract
        from PIL import Image, ImageOps

        cfg = self._cfg
        try:
            img = Image.open(io.BytesIO(contenido))
            # Varias camaras guardan la foto girada y la orientacion real en
            # los metadatos EXIF. Sin esto, una receta fotografiada en
            # vertical llega de lado y tesseract no lee casi nada.
            img = ImageOps.exif_transpose(img)
            # A escala de grises: el color no aporta al reconocimiento y
            # ocupa el triple de memoria.
            img = img.convert("L")
        except Exception as e:
            raise OcrFallo("No se pudo abrir la imagen.") from e

        try:
            texto = pytesseract.image_to_string(img, lang=cfg.ocr_idiomas)
            confianza = self._confianza(pytesseract, img, cfg.ocr_idiomas)
        except Exception as e:
            raise OcrFallo(f"El motor de lectura fallo: {e}") from e

        return TextoExtraido(
            texto=sanear_texto(texto),
            motor=f"tesseract/{self._version(pytesseract)}",
            idioma=cfg.ocr_idiomas,
            confianza=confianza,
        )

    @staticmethod
    def _confianza(pytesseract, img, idiomas: str) -> float | None:
        """Confianza media de las palabras que reconocio.

        Tesseract la da por palabra y marca con -1 las cajas que no son
        palabras, que hay que descartar o el promedio queda sin sentido.
        Si algo falla se devuelve nula: la confianza es un dato de ayuda y no
        vale perder el texto por ella.
        """
        try:
            datos = pytesseract.image_to_data(
                img, lang=idiomas, output_type=pytesseract.Output.DICT
            )
            valores = [float(c) for c in datos.get("conf", []) if float(c) >= 0]
            if not valores:
                return None
            return round(sum(valores) / len(valores), 2)
        except Exception:
            return None

    @staticmethod
    def _version(pytesseract) -> str:
        try:
            return str(pytesseract.get_tesseract_version()).split()[0]
        except Exception:
            return "desconocida"


# ---------------------------------------------------------------------------
# Sanitizacion
#
# Un documento subido es entrada no confiable en las dos puntas:
#
#   Entrada  la imagen puede venir mal formada, ser una bomba de
#            descompresion, traer metadatos con datos personales (GPS en el
#            EXIF) o ser un poliglota (una imagen que tambien es otra cosa).
#            Se valida la firma real, se decodifica con Pillow y se
#            REGENERA como JPEG limpio: lo que sale al proveedor externo son
#            pixeles nuevos, no los bytes que mando el usuario.
#
#   Salida   el texto lo escribio un modelo mirando una imagen que controla un
#            atacante. Una receta puede traer escrito "ignora las
#            instrucciones anteriores...". Ese texto despues alimenta la
#            busqueda y el contexto del asistente, asi que se trata como dato
#            hostil: sin caracteres de control ni invisibles, sin HTML, con
#            largo acotado y con las lineas que intentan dar ordenes a un
#            modelo reemplazadas por una marca.
# ---------------------------------------------------------------------------
_FIRMAS = {
    "image/jpeg": (b"\xff\xd8\xff",),
    "image/png": (b"\x89PNG\r\n\x1a\n",),
    "image/webp": (b"RIFF",),  # ademas lleva WEBP en los bytes 8..12
}

# Techo de pixeles al decodificar. Una PNG de 30 KB puede declarar 50000x50000
# y agotar la memoria al abrirla: Pillow lo corta si se fija este limite.
_MAX_PIXELES = 40_000_000
# Caja maxima recomendada por Nemotron Parse (ancho, alto).
_CAJA_MAX = (1664, 2048)

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
# Cero ancho, marcas de direccion y separadores invisibles: sirven para
# esconder instrucciones a la vista de quien revisa el texto.
_INVISIBLES = re.compile(r"[\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]")
_HTML = re.compile(r"<[^>\n]{0,200}>")
_URL = re.compile(r"(?i)\b(?:https?|ftp|file|data|javascript):[^\s]+")
_ORDENES = re.compile(
    r"(?i)("
    r"ignor[ae]\w*\s+(?:\w+\s+){0,3}(?:instruc|indicac|ordenes|prompt|regla)"
    r"|ignore\s+(?:\w+\s+){0,3}(?:instruction|prompt|rule)"
    r"|disregard\s+(?:\w+\s+){0,3}(?:instruction|prompt|rule)"
    r"|olvida\w*\s+(?:\w+\s+){0,3}(?:instruc|indicac|regla)"
    r"|system\s*prompt|prompt\s+del\s+sistema"
    r"|\bact(?:ú|u)a\s+como\b|\byou\s+are\s+now\b|\bnuevas?\s+instrucciones\b"
    r"|\bnew\s+instructions\b|\bassistant\s*:|\bsystem\s*:|<\|im_(?:start|end)\|>"
    r")"
)
_MARCA_OMITIDA = "[linea omitida por seguridad]"
_MAX_CARACTERES = 20_000


def sanear_texto(texto: str) -> str:
    """Deja el texto de un OCR listo para guardar y para citar.

    No intenta entender el texto: solo quita lo que no puede ser parte de un
    documento legitimo o que sirve para manipular a un modelo despues.
    """
    texto = unicodedata.normalize("NFC", texto or "")
    texto = _INVISIBLES.sub("", texto)
    texto = _CONTROL.sub("", texto.replace("\r\n", "\n").replace("\r", "\n"))
    texto = _HTML.sub(" ", texto)
    texto = _URL.sub("[enlace omitido]", texto)

    limpias: list[str] = []
    for linea in texto.split("\n"):
        linea = re.sub(r"[ \t]+", " ", linea).strip()
        if linea and _ORDENES.search(linea):
            linea = _MARCA_OMITIDA
        limpias.append(linea)
    # Sin mas de una linea en blanco seguida.
    salida = re.sub(r"\n{3,}", "\n\n", "\n".join(limpias)).strip()
    return salida[:_MAX_CARACTERES]


def sanear_imagen(contenido: bytes, mime_type: str) -> bytes:
    """Valida la imagen y la devuelve regenerada como JPEG sin metadatos.

    Lanza OcrFallo si no es una imagen valida o no coincide con lo declarado.
    """
    firmas = _FIRMAS.get(mime_type)
    if firmas is None:
        raise OcrFallo(f"Por ahora solo se leen imagenes JPEG, PNG o WebP, no {mime_type}.")
    if not any(contenido.startswith(f) for f in firmas) or (
        mime_type == "image/webp" and contenido[8:12] != b"WEBP"
    ):
        raise OcrFallo("El contenido del archivo no coincide con su tipo.")

    import io

    from PIL import Image, ImageOps

    Image.MAX_IMAGE_PIXELS = _MAX_PIXELES
    try:
        with Image.open(io.BytesIO(contenido)) as img:
            img.verify()
        # verify() deja el objeto inutilizable: se abre de nuevo para leer.
        with Image.open(io.BytesIO(contenido)) as img:
            if img.width * img.height > _MAX_PIXELES:
                raise OcrFallo("La imagen es demasiado grande para leerla.")
            img = ImageOps.exif_transpose(img)
            img.thumbnail(_CAJA_MAX)
            img = img.convert("RGB")
            salida = io.BytesIO()
            # Sin exif= ni info: los metadatos originales no se copian.
            img.save(salida, format="JPEG", quality=88)
            return salida.getvalue()
    except OcrFallo:
        raise
    except Exception as e:  # Pillow lanza varios tipos segun el defecto
        raise OcrFallo("No se pudo abrir la imagen.") from e


# Etiquetas de posicion y de clase que Nemotron Parse intercala en el texto:
# <x_0.54><y_0.03> ... <class_Text>. Sirven para maquetar, no son contenido.
_ETIQUETAS_PARSE = re.compile(r"<(?:x|y)_[0-9.]+>|<class_[A-Za-z\-]+>")
_MAX_RESPUESTA_BYTES = 1_000_000


class NemotronParse(OcrProvider):
    """Nemotron 3.5 Parse (NVIDIA): lee la pagina completa con su estructura.

    Es un modelo de OCR/maquetacion, no un chat: recibe la imagen como
    multipart y devuelve texto. No tiene prompt, asi que no hay instrucciones
    que un documento pueda secuestrar; aun asi su salida se sanea igual,
    porque el texto que devuelve es lo que habia escrito en la imagen.

    Defensas de este canal:
      - La imagen que sale es la regenerada (pixeles nuevos, sin metadatos,
        sin bytes extra al final, sin carga oculta en el contenedor).
      - La URL solo puede ser https y de un dominio nvidia.com, y no se
        siguen redirecciones: asi una variable de entorno mal puesta no
        manda la API key ni documentos de pacientes a un tercero.
      - La respuesta se acota en tamano y nunca se copia al mensaje de
        error, que puede llegar a la pantalla o a los registros.
    """

    def __init__(self, cfg: OcrSettings) -> None:
        self._cfg = cfg
        self._key = cfg.ocr_api_key or cfg.assistant_api_key

    @property
    def disponible(self) -> bool:
        return bool(self._key) and self._url_valida()

    def _url_valida(self) -> bool:
        from urllib.parse import urlparse

        u = urlparse(self._cfg.ocr_parse_url)
        host = (u.hostname or "").lower()
        return u.scheme == "https" and (host == "nvidia.com" or host.endswith(".nvidia.com"))

    async def extraer(self, *, contenido: bytes, mime_type: str) -> TextoExtraido:
        cfg = self._cfg
        if not self.disponible:
            raise OcrNotConfigured("La lectura de documentos con NVIDIA no esta configurada.")
        if len(contenido) > cfg.ocr_max_mb * 1024 * 1024:
            raise OcrFallo(f"El archivo pasa de {cfg.ocr_max_mb} MB y no se puede procesar.")

        limpia = await asyncio.to_thread(sanear_imagen, contenido, mime_type)

        import httpx

        try:
            async with httpx.AsyncClient(
                timeout=cfg.ocr_timeout_seconds, follow_redirects=False
            ) as http:
                resp = await http.post(
                    cfg.ocr_parse_url,
                    headers={"Authorization": f"Bearer {self._key}",
                             "Accept": "application/json"},
                    files={
                        "document": ("documento.jpg", limpia, "image/jpeg"),
                        "options": (None, json.dumps(
                            {"decoding": {"max_output_tokens": cfg.ocr_max_tokens}}),
                            "application/json"),
                    },
                )
        except httpx.HTTPError as e:
            raise OcrFallo(
                f"El servicio de lectura no respondio ({type(e).__name__})."
            ) from e

        if resp.status_code != 200:
            raise OcrFallo(f"El servicio de lectura rechazo la peticion ({resp.status_code}).")
        if len(resp.content) > _MAX_RESPUESTA_BYTES:
            raise OcrFallo("La respuesta del servicio de lectura es demasiado grande.")
        try:
            crudo = resp.json().get("content", "")
        except ValueError as e:
            raise OcrFallo("La respuesta del servicio de lectura no es valida.") from e
        if not isinstance(crudo, str):
            raise OcrFallo("La respuesta del servicio de lectura no es valida.")

        return TextoExtraido(
            texto=sanear_texto(_ETIQUETAS_PARSE.sub("", crudo)),
            motor="nvidia/nemotron-3.5-parse",
            idioma="auto",
            confianza=None,
        )


@lru_cache
def get_ocr() -> OcrProvider:
    cfg = get_ocr_settings()
    if cfg.ocr_provider == "tesseract":
        return Tesseract(cfg)
    if cfg.ocr_provider == "nvidia_parse":
        return NemotronParse(cfg)
    return NotConfigured()

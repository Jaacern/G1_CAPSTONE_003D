"""Proveedor de OCR: sacar el texto de una imagen o un PDF.

Mismo patron que storage.py, assistant_provider.py y speech_provider.py. La
aplicacion habla con una interfaz y el proveedor concreto se elige por
variable de entorno, asi que cambiar de motor es configuracion y no un
cambio de codigo.

    NotConfigured  cuando OCR_PROVIDER viene en 'none'. Devuelve un error
                   claro que la pantalla sabe distinguir.
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
    # none | tesseract
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
            texto=texto.strip(),
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


@lru_cache
def get_ocr() -> OcrProvider:
    cfg = get_ocr_settings()
    if cfg.ocr_provider == "tesseract":
        return Tesseract(cfg)
    return NotConfigured()

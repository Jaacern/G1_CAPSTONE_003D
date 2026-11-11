"""Proveedor de correo electrónico.

Mismo patrón que push_provider.py, storage.py, assistant_provider.py y
speech_provider.py. La aplicación habla con una interfaz y el proveedor
concreto se elige por variable de entorno. Cambiar de proveedor o encender
el envío real es configuración, no un cambio de código.

    NotConfigured  la que corre mientras EMAIL_PROVIDER=none.
                   No envía y lo dice. Es el valor por defecto.
    Smtp           Envío real por SMTP (con STARTTLS o SSL).

POR QUÉ NotConfigured NO FINGE EL ENVÍO
    Lo mismo que con push: decir "enviado" sin haber enviado nada es
    peligroso. El correo de recuperación de contraseña que nadie recibe
    dejó al usuario sin forma de entrar. Con el proveedor apagado cada
    intento queda registrado como fallido con el motivo.

CONFIGURACIÓN (variables de entorno / .env)
    EMAIL_PROVIDER          none | smtp          (defecto: none)
    EMAIL_HOST              servidor SMTP         (p.ej. smtp.gmail.com)
    EMAIL_PORT              puerto                (defecto: 587)
    EMAIL_USER              usuario               (dirección remitente)
    EMAIL_PASSWORD          contraseña            (secreto)
    EMAIL_USE_TLS           true/false            (defecto: true, STARTTLS)
    EMAIL_USE_SSL           true/false            (defecto: false, SSL directo)
    EMAIL_FROM              "Nombre <dir>"        (opcional, usa EMAIL_USER)
    EMAIL_TIMEOUT_SECONDS   segundos              (defecto: 10)
"""
from __future__ import annotations

import asyncio
import smtplib
import ssl
from abc import ABC, abstractmethod
from dataclasses import dataclass
from email.message import EmailMessage
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


@dataclass
class Envio:
    """Resultado de un intento de envío."""
    ok: bool
    error: str | None = None


class EmailSettings(BaseSettings):
    email_provider: str = "none"
    email_host: str = ""
    email_port: int = 587
    email_user: str = ""
    email_password: str = ""
    email_use_tls: bool = True   # STARTTLS
    email_use_ssl: bool = False  # SSL directo (puerto 465)
    email_from: str = ""         # "AgeCare <no-reply@agecare.cl>"
    email_timeout_seconds: int = 10

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    @property
    def remitente(self) -> str:
        return self.email_from or self.email_user


@lru_cache
def get_email_settings() -> EmailSettings:
    return EmailSettings()


class EmailProvider(ABC):
    @property
    @abstractmethod
    def disponible(self) -> bool: ...

    @abstractmethod
    async def enviar(
        self, *, destinatario: str, asunto: str, cuerpo_html: str,
        cuerpo_texto: str,
    ) -> Envio:
        """Envía un correo.

        Nunca lanza. Los errores van en el resultado para que quien llama
        pueda seguir enviando al resto de los destinatarios.
        """


class NotConfigured(EmailProvider):
    @property
    def disponible(self) -> bool:
        return False

    async def enviar(self, **_) -> Envio:
        return Envio(
            ok=False,
            error="El envío de correo no está configurado (EMAIL_PROVIDER=none).",
        )


class Smtp(EmailProvider):
    """Envío por SMTP estándar.

    Corre en un executor para no bloquear el event loop: smtplib es
    síncrono y una conexión que tarda (timeout, DNS lento) paraliza al
    worker de FastAPI si se llama directamente.
    """

    def __init__(self, cfg: EmailSettings) -> None:
        if not cfg.email_host:
            raise RuntimeError(
                "EMAIL_PROVIDER=smtp pero EMAIL_HOST está vacío."
            )
        if not cfg.email_user:
            raise RuntimeError(
                "EMAIL_PROVIDER=smtp pero EMAIL_USER está vacío."
            )
        self._cfg = cfg

    @property
    def disponible(self) -> bool:
        return True

    def _enviar_sync(
        self, destinatario: str, asunto: str,
        cuerpo_html: str, cuerpo_texto: str,
    ) -> Envio:
        cfg = self._cfg
        msg = EmailMessage()
        msg["Subject"] = asunto
        msg["From"] = cfg.remitente
        msg["To"] = destinatario
        msg.set_content(cuerpo_texto)
        msg.add_alternative(cuerpo_html, subtype="html")

        try:
            if cfg.email_use_ssl:
                ctx = ssl.create_default_context()
                with smtplib.SMTP_SSL(
                    cfg.email_host, cfg.email_port,
                    timeout=cfg.email_timeout_seconds, context=ctx,
                ) as s:
                    s.login(cfg.email_user, cfg.email_password)
                    s.send_message(msg)
            else:
                with smtplib.SMTP(
                    cfg.email_host, cfg.email_port,
                    timeout=cfg.email_timeout_seconds,
                ) as s:
                    if cfg.email_use_tls:
                        s.starttls(context=ssl.create_default_context())
                    s.login(cfg.email_user, cfg.email_password)
                    s.send_message(msg)
        except Exception as e:  # noqa: BLE001
            return Envio(ok=False,
                         error=str(e).splitlines()[0][:300])
        return Envio(ok=True)

    async def enviar(
        self, *, destinatario: str, asunto: str,
        cuerpo_html: str, cuerpo_texto: str,
    ) -> Envio:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None,
            self._enviar_sync,
            destinatario, asunto, cuerpo_html, cuerpo_texto,
        )


@lru_cache
def get_email() -> EmailProvider:
    cfg = get_email_settings()
    if cfg.email_provider.lower() == "smtp":
        return Smtp(cfg)
    return NotConfigured()

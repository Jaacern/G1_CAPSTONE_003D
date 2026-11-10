"""Proveedor de cobros: quien procesa el pago de una suscripcion.

Mismo patron que ocr_provider.py, storage.py y speech_provider.py. La
aplicacion habla con una interfaz y el proveedor concreto se elige por
variable de entorno (PAYMENT_PROVIDER).

    Simulated      el que corre hoy. Aprueba el cobro sin mover dinero.
    NotConfigured  PAYMENT_PROVIDER=none. Responde que el pago no esta
                   disponible, en vez de dejar contratar gratis.

POR QUE EXISTE UN PROVEEDOR SIMULADO
    Alloxentric aun no elige pasarela (Flow, Mercado Pago, Stripe, compras
    dentro de la app...). Esperar esa decision dejaria sin construir todo
    lo que depende de que exista un cobro: el alta de la suscripcion, su
    historial, la conversion y el panel. Con la interfaz definida, esa parte
    queda terminada y probada; elegir pasarela se reduce a escribir un
    adaptador de esta clase, sin tocar el resto.

LO QUE LA SIMULACION NO ES
    No cobra ni valida ninguna tarjeta. Sus referencias empiezan con 'SIM-'
    para que en billing_events se distingan de un cobro real a simple vista.
    No debe usarse en produccion: con PAYMENT_PROVIDER=simulated cualquiera
    puede pasar a premium gratis.
"""
from __future__ import annotations

import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass
from decimal import Decimal
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class PaymentNotConfigured(RuntimeError):
    """No hay una pasarela de pago conectada."""


@dataclass
class Cobro:
    ok: bool
    provider_ref: str | None
    # Identificador unico del aviso. billing_events lo exige unico, asi un
    # reintento de la pasarela no duplica el cobro.
    provider_event_id: str
    failure_reason: str | None = None


class PaymentSettings(BaseSettings):
    # none | simulated. Cuando haya pasarela se agrega su nombre aqui.
    payment_provider: str = "simulated"

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )


@lru_cache
def get_payment_settings() -> PaymentSettings:
    return PaymentSettings()


class PaymentProvider(ABC):
    @property
    @abstractmethod
    def nombre(self) -> str: ...

    @abstractmethod
    async def cobrar(
        self, *, user_id: str, monto: Decimal, moneda: str, descripcion: str
    ) -> Cobro:
        """Procesa un cobro. Un rechazo es Cobro(ok=False), no una excepcion."""


class NotConfigured(PaymentProvider):
    nombre = "none"

    async def cobrar(self, **_) -> Cobro:
        raise PaymentNotConfigured("El pago de suscripciones no esta disponible.")


class Simulated(PaymentProvider):
    nombre = "simulated"

    async def cobrar(
        self, *, user_id: str, monto: Decimal, moneda: str, descripcion: str
    ) -> Cobro:
        ref = f"SIM-{uuid.uuid4().hex[:16]}"
        return Cobro(ok=True, provider_ref=ref, provider_event_id=f"evt_{ref}")


def get_payment_provider() -> PaymentProvider:
    nombre = get_payment_settings().payment_provider.lower()
    if nombre == "simulated":
        return Simulated()
    return NotConfigured()

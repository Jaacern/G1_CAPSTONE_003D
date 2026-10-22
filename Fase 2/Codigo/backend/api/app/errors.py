"""Manejo de errores con el formato estándar de la sección 2.4 de la spec.

Todos los errores devuelven:
{
  "error": {
    "code": "...",           # código estable en MAYÚSCULAS
    "message": "...",        # mensaje en español para el usuario
    "details": [...] | null, # detalle por campo (validación Pydantic)
    "request_id": "..."      # trazabilidad
  }
}
"""
import uuid

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class ApiError(Exception):
    """Error de negocio con código interno y mensaje en español."""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        details: list | None = None,
    ):
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details
        super().__init__(message)


def _error_body(code: str, message: str, request: Request, details=None) -> dict:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    return {
        "error": {
            "code": code,
            "message": message,
            "details": details,
            "request_id": request_id,
        }
    }


# Mapea códigos HTTP genéricos a los códigos internos de la sección 2.5.
_HTTP_TO_CODE = {
    401: ("UNAUTHORIZED", "Tu sesión expiró. Vuelve a iniciar sesión."),
    403: ("FORBIDDEN", "No tienes permisos para realizar esta acción sobre este paciente."),
    404: ("NOT_FOUND", "El recurso solicitado no existe o no está disponible."),
    429: ("RATE_LIMITED", "Demasiadas solicitudes. Intenta de nuevo en unos segundos."),
    500: ("INTERNAL_ERROR", "Algo salió mal de nuestro lado. Intenta más tarde."),
}


def register_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error_handler(request: Request, exc: ApiError):
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_body(exc.code, exc.message, request, exc.details),
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_handler(request: Request, exc: RequestValidationError):
        details = [
            {"field": ".".join(str(p) for p in e["loc"]), "message": e["msg"]}
            for e in exc.errors()
        ]
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            content=_error_body(
                "VALIDATION_ERROR",
                "Hay datos inválidos en la solicitud. Revisa los campos marcados.",
                request,
                details,
            ),
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_handler(request: Request, exc: StarletteHTTPException):
        code, default_msg = _HTTP_TO_CODE.get(
            exc.status_code, ("INTERNAL_ERROR", "Algo salió mal de nuestro lado. Intenta más tarde.")
        )
        message = exc.detail if isinstance(exc.detail, str) else default_msg
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_body(code, message, request),
        )

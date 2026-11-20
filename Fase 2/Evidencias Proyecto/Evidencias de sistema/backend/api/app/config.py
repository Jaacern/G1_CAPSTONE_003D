"""Configuración de la aplicación, leída desde variables de entorno / .env."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict

# Secreto JWT por defecto, inseguro y publico (esta en el repo). Nunca debe
# usarse para firmar tokens reales: quien lea el codigo podria forjar la
# sesion de cualquier usuario y tokens de subida/descarga de archivos. Se
# mantiene como valor por defecto SOLO para que el import del modulo no exija
# la variable en herramientas y tests que no firman nada; el arranque de la
# API lo rechaza (ver _rechazar_secreto_inseguro y app.main).
_INSECURE_JWT_DEFAULT = "dev-secret-cambiar-en-produccion"
_MIN_JWT_SECRET_LEN = 32


class Settings(BaseSettings):
    # --- Base de datos (mismas credenciales del docker-compose de la BD) ---
    postgres_user: str = "agecare"
    postgres_password: str = "agecare_local_2026"
    postgres_db: str = "agecare"
    postgres_host: str = "127.0.0.1"
    postgres_port: int = 5432

    # --- Zona horaria de la operacion ---
    # AgeCare opera en Chile. No es un detalle de presentacion: la base
    # guarda timestamptz, que es un instante, y para saber a que DIA
    # pertenece ese instante hay que decir en que pais. "Las dosis de hoy"
    # y "las tareas completadas hoy" no significan nada sin esto.
    #
    # Queda como variable de entorno porque es lo unico que cambiaria si
    # manana el servicio opera en otro pais, pero el valor por defecto es
    # el real.
    timezone: str = "America/Santiago"

    # --- Seguridad / JWT ---
    # El secreto DEBE venir del entorno (JWT_SECRET). El valor por defecto es
    # el centinela inseguro de arriba; la API se niega a arrancar con el (ver
    # ensure_secure_jwt_secret, llamado desde app.main). DevSecOps — F5.
    jwt_secret: str = _INSECURE_JWT_DEFAULT
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 30

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def database_url(self) -> str:
        """URL de conexión async para SQLAlchemy (driver asyncpg)."""
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()


def ensure_secure_jwt_secret(settings: "Settings | None" = None) -> None:
    """Falla si el secreto JWT es el default inseguro o demasiado corto.

    Se llama al arrancar la API (app.main). Antes, config.py traia el secreto
    hardcodeado y docker-compose lo reponia con `:-` si faltaba la variable,
    asi que un despliegue sin JWT_SECRET arrancaba firmando con un secreto
    publico del repo: cualquiera podia forjar la sesion de otro usuario y los
    tokens de subida/descarga de archivos. Mejor que el contenedor NO parta a
    que parta inseguro, igual que ya se hace cuando falla la migracion.

    No se valida en el __init__ del modelo a proposito: importar `config` no
    debe exigir la variable (hay herramientas y tests que no firman tokens).
    El punto de control es el arranque del servicio.

    DevSecOps — hallazgo F5 de la auditoria de seguridad (jaacern, 2026-11).
    """
    s = settings or get_settings()
    if s.jwt_secret == _INSECURE_JWT_DEFAULT:
        raise RuntimeError(
            "JWT_SECRET no esta configurado: la API se niega a arrancar con el "
            "secreto por defecto del repositorio. Define JWT_SECRET con un valor "
            "largo y aleatorio (p. ej. `openssl rand -hex 32`)."
        )
    if len(s.jwt_secret) < _MIN_JWT_SECRET_LEN:
        raise RuntimeError(
            f"JWT_SECRET es demasiado corto ({len(s.jwt_secret)} caracteres); "
            f"usa al menos {_MIN_JWT_SECRET_LEN}. Genera uno con "
            "`openssl rand -hex 32`."
        )

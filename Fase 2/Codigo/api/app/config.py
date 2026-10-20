"""Configuración de la aplicación, leída desde variables de entorno / .env."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # --- Base de datos (mismas credenciales del docker-compose de la BD) ---
    postgres_user: str = "agecare"
    postgres_password: str = "agecare_local_2026"
    postgres_db: str = "agecare"
    postgres_host: str = "127.0.0.1"
    postgres_port: int = 5432

    # --- Seguridad / JWT ---
    # OJO: en producción el secreto debe venir del entorno, nunca hardcodeado.
    jwt_secret: str = "dev-secret-cambiar-en-produccion"
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

"""Punto de entrada de la API AgeCare (FastAPI)."""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.errors import register_error_handlers
from app.routers import alerts, auth, health, medications, patients, vitals

app = FastAPI(
    title="AgeCare API",
    version="0.1.0",
    description=(
        "API del backend AgeCare. Módulos implementados sobre las tablas SQL "
        "existentes: 3 (auth), 4 (pacientes/onboarding), 5 (vitals/semáforo), "
        "6 (medicamentos/adherencia), 9 (alertas/SOS)."
    ),
)

# CORS: permite que un HTML/frontend en otro origen (otra máquina o puerto)
# llame a la API desde el navegador. Abierto para desarrollo; en producción
# se debe restringir allow_origins a los dominios reales del frontend.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

register_error_handlers(app)

# Endpoints operacionales (fuera de /api/v1).
app.include_router(health.router)

# Módulos de negocio (todos cuelgan de /api/v1).
app.include_router(auth.router)
app.include_router(patients.router)
app.include_router(vitals.router)
app.include_router(medications.router)
app.include_router(alerts.router)


@app.get("/", tags=["root"])
async def root():
    return {"service": "agecare-api", "docs": "/docs"}

"""Punto de entrada de la API AgeCare (FastAPI)."""
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse

from app.errors import register_error_handlers
from app.routers import alerts, auth, health, medications, patients, vitals

# Directorio de archivos estáticos del test client.
# Está dentro de app/static/ → se copia al contenedor con el COPY de la imagen.
# Se puede sobreescribir con AGECARE_FRONT_DIR para apuntar a otro lugar.
_FRONT_DIR = os.environ.get(
    "AGECARE_FRONT_DIR",
    os.path.join(os.path.dirname(__file__), "static")
)


def _custom_swagger_html() -> str:
    """Swagger UI estándar de FastAPI con un botón TEST en el header."""
    return """<!DOCTYPE html>
<html>
<head>
  <title>AgeCare API – Docs</title>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" type="text/css"
        href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" >
  <style>
    body { margin: 0; background: #fafafa; }
    /* ── Test banner ── */
    #test-banner {
      background: linear-gradient(135deg, #3b6fd4, #2455b3);
      color: #fff;
      padding: 10px 20px;
      display: flex;
      align-items: center;
      gap: 16px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 13px;
    }
    #test-banner a {
      color: #fff;
      text-decoration: none;
      font-weight: 700;
      padding: 6px 16px;
      border: 2px solid rgba(255,255,255,0.7);
      border-radius: 8px;
      transition: background .15s;
    }
    #test-banner a:hover { background: rgba(255,255,255,0.2); }
    #test-banner .spacer { flex: 1; }
    #test-banner .pill {
      background: rgba(255,255,255,0.15);
      padding: 3px 10px;
      border-radius: 20px;
      font-size: 11px;
    }
  </style>
</head>
<body>
<div id="test-banner">
  <span>🩺 <strong>AgeCare API</strong></span>
  <span class="pill">v0.1.0</span>
  <span class="spacer"></span>
  <a href="/test" target="_blank">🧪 TEST — Abrir cliente de prueba</a>
</div>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"> </script>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-standalone-preset.js"> </script>
<script>
window.onload = function() {
  SwaggerUIBundle({
    url: "/openapi.json",
    dom_id: '#swagger-ui',
    presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
    layout: "StandaloneLayout",
    deepLinking: true,
    persistAuthorization: true,
  })
}
</script>
</body>
</html>"""


app = FastAPI(
    title="AgeCare API",
    version="0.1.0",
    description=(
        "API del backend AgeCare. Módulos implementados sobre las tablas SQL "
        "existentes: 3 (auth), 4 (pacientes/onboarding), 5 (vitals/semáforo), "
        "6 (medicamentos/adherencia), 9 (alertas/SOS)."
    ),
    # Desactivamos los docs automáticos para usar nuestra versión customizada.
    docs_url=None,
    redoc_url=None,
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
    return {"service": "agecare-api", "docs": "/docs", "test": "/test"}


# ── Swagger UI personalizado con botón TEST ──────────────────────
@app.get("/docs", include_in_schema=False)
async def custom_swagger_ui():
    return HTMLResponse(_custom_swagger_html())


# ── Cliente de prueba: sirve el HTML y los assets desde /front ───
@app.get("/test", include_in_schema=False)
async def test_client():
    """Sirve el cliente de prueba HTML (test.html) desde la carpeta front/."""
    path = os.path.join(_FRONT_DIR, "test.html")
    if os.path.exists(path):
        return FileResponse(path, media_type="text/html")
    return HTMLResponse("<h1>test.html no encontrado</h1><p>Asegúrate de que front/test.html existe.</p>", status_code=404)


@app.get("/test/Wireframe_Familiar_v1.html", include_in_schema=False)
async def wireframe_familiar():
    path = os.path.join(_FRONT_DIR, "Wireframe_Familiar_v1.html")
    return FileResponse(path, media_type="text/html") if os.path.exists(path) else HTMLResponse("Not found", 404)


@app.get("/test/Wireframe_Suite_v1.html", include_in_schema=False)
async def wireframe_suite():
    path = os.path.join(_FRONT_DIR, "Wireframe_Suite_v1.html")
    return FileResponse(path, media_type="text/html") if os.path.exists(path) else HTMLResponse("Not found", 404)


@app.get("/test/{filename:path}", include_in_schema=False)
async def test_static(filename: str):
    """Sirve assets estáticos del directorio front/ (imágenes, etc.)."""
    # Protección básica: bloquea path traversal
    safe = os.path.normpath(filename).lstrip("/")
    if ".." in safe:
        return HTMLResponse("Forbidden", status_code=403)
    path = os.path.join(_FRONT_DIR, safe)
    if os.path.exists(path) and os.path.isfile(path):
        return FileResponse(path)
    return HTMLResponse("Not found", status_code=404)

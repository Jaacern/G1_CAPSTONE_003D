# API AgeCare — Python 3.12 (stack pedido por la empresa, spec 1.1)
FROM python:3.12-slim

# No generar .pyc y salida sin buffer para ver logs en tiempo real
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /code

# Instalar dependencias primero para aprovechar la caché de capas
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# Copiar el código de la aplicación
COPY app ./app

EXPOSE 8000

# Uvicorn sirviendo la app FastAPI
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

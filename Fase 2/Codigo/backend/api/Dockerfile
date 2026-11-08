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

# Guiones de arranque: uno pone la base al día y sirve la API, el otro
# corre las tareas del día en bucle. Van en la misma imagen porque usan el
# mismo código; el docker-compose decide cuál ejecuta cada servicio.
COPY entrypoint.sh mantenimiento.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/mantenimiento.sh

EXPOSE 8000

# Migra y después sirve. El orden importa: una API que acepta peticiones
# contra un esquema viejo falla en endpoints sueltos, y eso cuesta mucho
# más de diagnosticar que un contenedor que no parte.
CMD ["/usr/local/bin/entrypoint.sh"]

# API AgeCare — Python 3.12 (stack pedido por la empresa, spec 1.1)
FROM python:3.12-slim

# No generar .pyc y salida sin buffer para ver logs en tiempo real
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /code

# Tesseract y sus datos de castellano, para leer el texto de las recetas y
# los documentos que la gente fotografia. Va antes de pip para que una capa
# que casi nunca cambia no se reconstruya cada vez que se toca una
# dependencia de Python.
#
# El paquete de ingles entra como dependencia de tesseract-ocr, y se pide
# tambien el de castellano porque una receta chilena mezcla los dos: los
# nombres de farmacos y varias unidades vienen en ingles.
#
# --no-install-recommends deja fuera unos 200 MB de paquetes de otros
# idiomas que no se usan.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tesseract-ocr \
        tesseract-ocr-spa \
    && rm -rf /var/lib/apt/lists/*

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

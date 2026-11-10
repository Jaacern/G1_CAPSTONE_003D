"""Rate limiting por IP (DevSecOps).

Contexto de la auditoria de seguridad (jaacern, 2026-11), hallazgos F3 y F4:
la API no tenia ningun limitador, de modo que login, refresh, la vinculacion
de dispositivos por codigo de 6 digitos, el SOS y los servicios de IA/voz
quedaban abiertos a fuerza bruta y a abuso de recursos (costo por token del
proveedor de IA incluido). El codigo de error RATE_LIMITED ya existia en
errors.py pero nada lo disparaba.

Se usa SlowAPI con clave por IP de origen. El almacenamiento es en memoria, que
alcanza para un unico worker (el caso de la demo y del despliegue actual detras
de Cloudflare). Si manana se corre con varios workers o replicas, el conteo
deja de ser global: hay que mover `storage_uri` a Redis para que el limite sea
consistente entre procesos. Queda anotado a proposito, porque un limitador que
cada worker cuenta por separado es una falsa sensacion de seguridad.

Nota sobre la IP de origen: detras de un proxy/tunel (Cloudflare), la IP que ve
la app es la del proxy salvo que se lea X-Forwarded-For. get_remote_address usa
request.client.host; si se despliega tras proxy, configurar el proxy para
propagar la IP real o derivar la clave de la cabecera de confianza. No se
confia en X-Forwarded-For por defecto porque es falsificable si el proxy no la
sanea (se elevaria el limite simplemente rotando la cabecera).
"""
from slowapi import Limiter
from slowapi.util import get_remote_address

# Limite global suave: ultima linea de defensa para cualquier endpoint que no
# declare uno propio. No reemplaza a los limites especificos de abajo.
limiter = Limiter(key_func=get_remote_address, default_limits=["240/minute"])

# Limites especificos de los endpoints sensibles. Se exponen como constantes
# para que el valor y su motivo vivan en un solo lugar y los tests puedan
# leerlos en vez de copiarlos.
#
# Los numeros buscan no estorbar al uso legitimo (una persona inicia sesion
# unas pocas veces, una cuidadora vincula un reloj de vez en cuando) y si
# cortar el barrido automatizado.
LIMIT_LOGIN = "10/minute"        # F4: fuerza bruta de credenciales.
LIMIT_REFRESH = "60/minute"      # rotacion normal; corta el abuso.
LIMIT_DEVICE_LINK = "12/minute"  # F1/F3: fuerza bruta del codigo de 6 digitos.
# Canje del codigo de invitacion al circulo de cuidado (6 digitos). Cubre
# /invitations/accept y /auth/register, que tambien acepta el codigo: sin
# limite en las dos puertas, cerrar una sola no serviria de nada.
LIMIT_INVITE_CODE = "12/minute"
LIMIT_SOS = "20/minute"          # evita spam de alertas criticas.
LIMIT_AI = "20/minute"           # IA/voz: tienen costo por uso del proveedor.

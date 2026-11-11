"""Pruebas del proveedor de push, sin salir a internet.

El envio real a Firebase no se puede probar sin un proyecto de Firebase. Lo
que si se puede, y es donde estan los errores que cuestan, es todo lo que
hay antes y despues: que el JWT de la cuenta de servicio este bien firmado,
que el token de acceso se pida una vez y se reuse, que el mensaje tenga la
forma que FCM exige, y que cada respuesta de error se lea como lo que es.

Para eso se reemplaza el transporte HTTP por uno falso que responde como
responden Google y FCM.
"""
import asyncio, json, os, sys
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")

import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

import httpx  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from jose import jwt  # noqa: E402

from app import push_provider as pp  # noqa: E402

ok = fallo = 0
def check(n, c, d=""):
    global ok, fallo
    if c: ok += 1; print(f"  ok   {n}")
    else: fallo += 1; print(f"  FALLA {n} {d}")


# Una llave RSA de verdad, generada aca, para que la firma sea verificable.
_llave = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PRIVADA = _llave.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
    serialization.NoEncryption()).decode()
PUBLICA = _llave.public_key().public_bytes(
    serialization.Encoding.PEM,
    serialization.PublicFormat.SubjectPublicKeyInfo).decode()
CUENTA = json.dumps({"project_id": "agecare-prueba",
                     "client_email": "push@agecare-prueba.iam.gserviceaccount.com",
                     "private_key": PRIVADA})


class Servidor:
    """Hace de Google y de FCM. Anota lo que recibe."""

    def __init__(self):
        self.pedidos_de_token = []
        self.mensajes = []
        self.respuesta_fcm = (200, {"name": "projects/x/messages/1"})
        self.caido = False

    def atender(self, request: httpx.Request) -> httpx.Response:
        if self.caido:
            raise httpx.ConnectError("sin red")
        if request.url.host == "oauth2.googleapis.com":
            cuerpo = dict(p.split("=", 1) for p in request.content.decode().split("&"))
            self.pedidos_de_token.append(cuerpo)
            return httpx.Response(200, json={"access_token": "acceso-123",
                                             "expires_in": 3600})
        self.mensajes.append({"url": str(request.url),
                              "auth": request.headers.get("authorization"),
                              "json": json.loads(request.content)})
        codigo, cuerpo = self.respuesta_fcm
        return httpx.Response(codigo, json=cuerpo)


SERVIDOR = Servidor()
_ClienteReal = httpx.AsyncClient


class _ClienteFalso(_ClienteReal):
    def __init__(self, *a, **kw):
        kw["transport"] = httpx.MockTransport(SERVIDOR.atender)
        super().__init__(*a, **kw)


def fcm(**extra):
    return pp.Fcm(pp.PushSettings(push_provider="fcm",
                                  fcm_credentials_json=CUENTA, **extra))


async def main():
    httpx.AsyncClient = _ClienteFalso
    try:
        # ---------------- apagado ----------------
        print("sin configurar")
        nc = pp.NotConfigured()
        r = await nc.enviar(token="t", titulo="a", cuerpo="b", datos={})
        check("no esta disponible", nc.disponible is False)
        check("no finge el envio: responde que no se envio y por que",
              r.ok is False and r.token_invalido is False
              and "no esta configurado" in r.error, r)

        # ---------------- configuracion ----------------
        print("configuracion")
        for nombre, cfg in (
            ("sin credenciales", pp.PushSettings(push_provider="fcm")),
            ("con un JSON que no es una cuenta de servicio",
             pp.PushSettings(push_provider="fcm", fcm_credentials_json='{"a": 1}')),
            ("con algo que no es JSON",
             pp.PushSettings(push_provider="fcm", fcm_credentials_json="hola")),
            ("con un archivo que no existe",
             pp.PushSettings(push_provider="fcm",
                             fcm_credentials_file="/no/existe.json")),
        ):
            try:
                pp.Fcm(cfg)
                check(f"fcm {nombre} se niega a arrancar", False)
            except RuntimeError as e:
                check(f"fcm {nombre} se niega a arrancar, con un mensaje claro",
                      "FCM" in str(e) or "fcm" in str(e), str(e))
        ruta = "/tmp/agecare-prueba-fcm.json"
        with open(ruta, "w", encoding="utf-8") as f:
            f.write(CUENTA)
        p = pp.Fcm(pp.PushSettings(push_provider="fcm", fcm_credentials_file=ruta))
        os.remove(ruta)
        check("acepta las credenciales desde un archivo", p.disponible is True)

        # ---------------- el envio ----------------
        print("envio")
        p = fcm()
        r = await p.enviar(token="tok-1", titulo="Elena · Posible caída",
                           cuerpo="El reloj detectó una caída.",
                           datos={"type": "alert", "alert_id": "abc", "n": 7},
                           canal="falls", critica=True)
        check("un envio aceptado por FCM se informa como enviado",
              r.ok is True and r.error is None, r)

        pedido = SERVIDOR.pedidos_de_token[0]
        from urllib.parse import unquote
        afirmacion = jwt.decode(unquote(pedido["assertion"]), PUBLICA,
                                algorithms=["RS256"],
                                audience="https://oauth2.googleapis.com/token")
        check("el JWT va firmado con la llave de la cuenta de servicio",
              afirmacion["iss"] == "push@agecare-prueba.iam.gserviceaccount.com",
              afirmacion)
        check("y pide solo el permiso de mensajeria",
              afirmacion["scope"] ==
              "https://www.googleapis.com/auth/firebase.messaging", afirmacion)
        check("vence en una hora, que es lo maximo que Google acepta",
              afirmacion["exp"] - afirmacion["iat"] == 3600)

        m = SERVIDOR.mensajes[0]
        check("el mensaje va al proyecto de las credenciales",
              m["url"].endswith("/v1/projects/agecare-prueba/messages:send"),
              m["url"])
        check("con el token de acceso que entrego Google",
              m["auth"] == "Bearer acceso-123", m["auth"])
        msg = m["json"]["message"]
        check("lleva el token del aparato, el titulo y el cuerpo",
              msg["token"] == "tok-1"
              and msg["notification"] == {"title": "Elena · Posible caída",
                                          "body": "El reloj detectó una caída."},
              msg)
        check("los datos viajan todos como texto, que es lo que FCM exige",
              msg["data"] == {"type": "alert", "alert_id": "abc", "n": "7"},
              msg["data"])
        check("en Android va con prioridad alta y por el canal pedido",
              msg["android"]["priority"] == "HIGH"
              and msg["android"]["notification"]["channel_id"] == "falls",
              msg["android"])
        check("en iOS una critica atraviesa el modo de concentracion",
              msg["apns"]["payload"]["aps"]["interruption-level"] == "time-sensitive"
              and msg["apns"]["headers"]["apns-priority"] == "10", msg["apns"])

        await p.enviar(token="tok-2", titulo="a", cuerpo="b", datos={})
        check("el token de acceso se pide una vez y se reusa",
              len(SERVIDOR.pedidos_de_token) == 1, len(SERVIDOR.pedidos_de_token))
        check("un aviso comun en iOS no interrumpe como una critica",
              SERVIDOR.mensajes[1]["json"]["message"]["apns"]["payload"]["aps"]
              ["interruption-level"] == "active")
        p._vence = 0
        await p.enviar(token="tok-2", titulo="a", cuerpo="b", datos={})
        check("y se renueva cuando vence", len(SERVIDOR.pedidos_de_token) == 2,
              len(SERVIDOR.pedidos_de_token))

        # Diez envios a la vez con el token vencido: un solo pedido.
        p2 = fcm()
        antes = len(SERVIDOR.pedidos_de_token)
        await asyncio.gather(*(p2.enviar(token=f"t{i}", titulo="a", cuerpo="b",
                                         datos={}) for i in range(10)))
        check("diez envios simultaneos piden un solo token de acceso",
              len(SERVIDOR.pedidos_de_token) - antes == 1,
              len(SERVIDOR.pedidos_de_token) - antes)

        # ---------------- las fallas ----------------
        print("fallas")
        SERVIDOR.respuesta_fcm = (404, {"error": {
            "code": 404, "status": "NOT_FOUND",
            "message": "Requested entity was not found.",
            "details": [{"errorCode": "UNREGISTERED"}]}})
        r = await p.enviar(token="muerto", titulo="a", cuerpo="b", datos={})
        check("aplicacion desinstalada: el token se da por muerto",
              r.ok is False and r.token_invalido is True
              and "UNREGISTERED" in r.error, r)

        SERVIDOR.respuesta_fcm = (400, {"error": {
            "code": 400, "status": "INVALID_ARGUMENT",
            "message": "The registration token is not a valid FCM registration token"}})
        r = await p.enviar(token="mal", titulo="a", cuerpo="b", datos={})
        check("token mal formado: tambien se da por muerto",
              r.ok is False and r.token_invalido is True, r)

        SERVIDOR.respuesta_fcm = (400, {"error": {
            "code": 400, "status": "INVALID_ARGUMENT",
            "message": "Invalid value at 'message.data[0].value'"}})
        r = await p.enviar(token="bueno", titulo="a", cuerpo="b", datos={})
        check("mensaje mal armado de nuestro lado: el token NO se toca",
              r.ok is False and r.token_invalido is False, r)

        SERVIDOR.respuesta_fcm = (503, {"error": {
            "code": 503, "status": "UNAVAILABLE", "message": "The service is down"}})
        r = await p.enviar(token="bueno", titulo="a", cuerpo="b", datos={})
        check("servicio caido: falla pasajera, el token se conserva",
              r.ok is False and r.token_invalido is False
              and "UNAVAILABLE" in r.error, r)

        r = pp._leer_error(500, "<html>error</html>")
        check("una respuesta que no es JSON no rompe la lectura del error",
              r.ok is False and r.token_invalido is False and "500" in r.error, r)
        check("el error cabe en la columna error_detail",
              len(pp._leer_error(500, "x" * 5000).error) <= 300)

        SERVIDOR.caido = True
        r = await p.enviar(token="bueno", titulo="a", cuerpo="b", datos={})
        SERVIDOR.caido = False
        check("sin red no lanza: devuelve la falla y conserva el token",
              r.ok is False and r.token_invalido is False
              and "No se pudo contactar" in r.error, r)

        # ---------------- la eleccion ----------------
        print("eleccion por variable de entorno")
        pp.get_push.cache_clear(); pp.get_push_settings.cache_clear()
        os.environ["PUSH_PROVIDER"] = "none"
        check("con none entrega el proveedor apagado",
              isinstance(pp.get_push(), pp.NotConfigured))
        pp.get_push.cache_clear(); pp.get_push_settings.cache_clear()
        os.environ["PUSH_PROVIDER"] = "fcm"
        os.environ["FCM_CREDENTIALS_JSON"] = CUENTA
        check("con fcm y credenciales entrega FCM", isinstance(pp.get_push(), pp.Fcm))
        del os.environ["FCM_CREDENTIALS_JSON"]
        os.environ["PUSH_PROVIDER"] = "none"
        pp.get_push.cache_clear(); pp.get_push_settings.cache_clear()
    finally:
        httpx.AsyncClient = _ClienteReal

    print(f"\n{ok} ok, {fallo} fallas")
    return 1 if fallo else 0

sys.exit(asyncio.run(main()))

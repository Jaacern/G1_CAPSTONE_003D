"""Plantillas de los correos de AgeCare.

Un solo lugar para el diseño, para que el correo de recuperación de
contraseña y los que vengan después (aviso alternativo, invitaciones) salgan
con la misma cara. Las funciones devuelven (asunto, html, texto): el texto
plano va siempre, porque hay clientes que no muestran HTML y porque un correo
sin alternativa de texto suele terminar en spam.

DISEÑO
    Tablas con estilos en línea y ancho de 600 px, que es lo que soportan
    Gmail, Outlook y los clientes móviles. Nada de CSS externo ni de
    JavaScript: los clientes de correo los descartan.

    La paleta es la del logo de AgeCare (el mismo de la pantalla de inicio):
    índigo del nombre, azul, amarillo y lavanda de los pétalos. El logo va
    en pequeño arriba, sobre fondo blanco, como en la pantalla de inicio.

EL LOGO VIAJA DENTRO DEL CORREO
    app/assets/agecare-logo-email.png es el logo de la app recortado y
    reducido (220 px, el doble de lo que se muestra, para pantallas de alta
    densidad). Se adjunta como imagen en línea (cid:agecare-logo) en vez de
    enlazarla: no depende de ningún servidor y los clientes no la bloquean
    como imagen remota. Si EMAIL_LOGO_URL está definida se usa esa dirección
    en su lugar.

LO QUE DEPENDE DE LA CONFIGURACIÓN
    El enlace a términos y política de privacidad sale de EMAIL_TERMS_URL y
    EMAIL_PRIVACY_URL. Si no están definidas no se inventa ninguna dirección:
    los textos legales se muestran sin enlace.
"""
from __future__ import annotations

from functools import lru_cache
from html import escape
from pathlib import Path

from app.email_provider import get_email_settings

# Paleta del logo (muestreada del PNG de la pantalla de inicio).
_INDIGO = "#192998"        # "AgeCare", títulos y texto fuerte
_AZUL = "#344CC8"          # pétalo azul: botones, enlaces, borde del código
_AMARILLO = "#FEC502"      # pétalo amarillo: acento
_LAVANDA = "#B39FFE"       # pétalo lavanda: acento suave
_LAVANDA_CLARO = "#F1EDFF" # fondo del código y del pie
_AMARILLO_CLARO = "#FFF6D6"
_AMARILLO_TEXTO = "#6B4F00"  # texto legible sobre el amarillo claro
_TEXTO = "#1F2340"
_TEXTO_SUAVE = "#5B6080"

_CID_LOGO = "agecare-logo"
_RUTA_LOGO = Path(__file__).resolve().parent / "assets" / "agecare-logo-email.png"
# Ancho al que se muestra el logo. El archivo mide el doble.
_ANCHO_LOGO = 88


@lru_cache
def _bytes_logo() -> bytes | None:
    try:
        return _RUTA_LOGO.read_bytes()
    except OSError:
        return None


def logo_inline() -> dict[str, bytes]:
    """Imágenes que hay que adjuntar para que el HTML muestre el logo.

    Se pasa tal cual a EmailProvider.enviar(imagenes_inline=...). Vacío si el
    logo viene de una URL configurada o si el archivo no está.
    """
    if get_email_settings().email_logo_url:
        return {}
    datos = _bytes_logo()
    return {_CID_LOGO: datos} if datos else {}


def _enlace(texto: str, url: str) -> str:
    """El texto como enlace si hay URL configurada; si no, el texto solo."""
    if url:
        return (f'<a href="{escape(url, quote=True)}" '
                f'style="color:{_AZUL};text-decoration:underline;">'
                f"{escape(texto)}</a>")
    return escape(texto)


def _logo_html() -> str:
    cfg = get_email_settings()
    if cfg.email_logo_url:
        src = escape(cfg.email_logo_url, quote=True)
    elif _bytes_logo() is not None:
        src = f"cid:{_CID_LOGO}"
    else:
        # Sin imagen disponible: el nombre en texto, con el color del logo.
        return (f'<span style="font-family:Arial,Helvetica,sans-serif;'
                f'font-size:26px;font-weight:700;color:{_INDIGO};">AgeCare</span>')
    return (f'<img src="{src}" alt="AgeCare" width="{_ANCHO_LOGO}" '
            f'style="display:block;width:{_ANCHO_LOGO}px;height:auto;border:0;">')


def _marco(*, titulo_pestana: str, cuerpo: str, pie_extra: str = "") -> str:
    """Estructura común: cabecera con el logo, contenido y pie legal."""
    cfg = get_email_settings()
    terminos = _enlace("Términos y condiciones", cfg.email_terms_url)
    privacidad = _enlace("Política de privacidad", cfg.email_privacy_url)

    return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(titulo_pestana)}</title>
</head>
<body style="margin:0;padding:0;background:{_LAVANDA_CLARO};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
       style="background:{_LAVANDA_CLARO};">
  <tr><td align="center" style="padding:24px 12px;">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"
           style="width:100%;max-width:600px;background:#FFFFFF;border-radius:12px;
                  overflow:hidden;font-family:Arial,Helvetica,sans-serif;color:{_TEXTO};">
      <tr><td align="center" style="background:#FFFFFF;padding:24px 32px 16px;">
        {_logo_html()}
      </td></tr>
      <tr><td style="padding:0;font-size:0;line-height:0;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td width="50%" height="5" style="background:{_AZUL};font-size:0;line-height:0;">&nbsp;</td>
            <td width="25%" height="5" style="background:{_AMARILLO};font-size:0;line-height:0;">&nbsp;</td>
            <td width="25%" height="5" style="background:{_LAVANDA};font-size:0;line-height:0;">&nbsp;</td>
          </tr>
        </table>
      </td></tr>
      <tr><td style="padding:32px;font-size:16px;line-height:1.55;">
        {cuerpo}
      </td></tr>
      <tr><td style="background:{_LAVANDA_CLARO};padding:20px 32px;font-size:12px;
                     line-height:1.6;color:{_TEXTO_SUAVE};">
        {pie_extra}
        <div>{terminos} &nbsp;·&nbsp; {privacidad}</div>
        <div style="margin-top:8px;">
          Recibiste este correo porque alguien pidió una acción sobre una cuenta de
          AgeCare con esta dirección. Si no fuiste tú, puedes ignorarlo.
        </div>
        <div style="margin-top:8px;">&copy; AgeCare. Este es un mensaje automático,
          por favor no respondas a este correo.</div>
      </td></tr>
    </table>
  </td></tr>
</table>
</body>
</html>"""


def correo_recuperacion(*, nombre: str, codigo: str, minutos: int,
                        intentos: int) -> tuple[str, str, str]:
    """Correo con el código para recuperar la contraseña (RF-05).

    El código se muestra separado en dos mitades (123 456) para leerlo y
    dictarlo mejor; la app lo acepta con o sin espacio.
    """
    nombre_seguro = escape(nombre or "")
    codigo_legible = f"{codigo[:3]} {codigo[3:]}" if len(codigo) == 6 else codigo
    saludo = f"Hola, {nombre_seguro}." if nombre_seguro else "Hola."

    cuerpo = f"""
        <h1 style="margin:0 0 12px;font-size:22px;color:{_INDIGO};">
          Recupera tu contraseña
        </h1>
        <p style="margin:0 0 16px;">{saludo}</p>
        <p style="margin:0 0 20px;">
          Recibimos una solicitud para restablecer la contraseña de tu cuenta.
          Ingresa este código en la aplicación para continuar:
        </p>
        <table role="presentation" align="center" cellpadding="0" cellspacing="0"
               border="0" style="margin:0 auto 20px;">
          <tr><td style="background:{_LAVANDA_CLARO};border:2px solid {_AZUL};
                         border-radius:10px;padding:16px 28px;text-align:center;">
            <span style="font-family:'Courier New',Courier,monospace;font-size:36px;
                         font-weight:700;letter-spacing:6px;color:{_INDIGO};">
              {escape(codigo_legible)}
            </span>
          </td></tr>
        </table>
        <p style="margin:0 0 8px;text-align:center;font-size:15px;">
          El código vence en <strong>{minutos} minutos</strong>.
        </p>
        <p style="margin:0 0 20px;text-align:center;font-size:13px;color:{_TEXTO_SUAVE};">
          Tiene {intentos} intentos: pasado ese límite deberás pedir uno nuevo.
        </p>
        <p style="margin:0;padding:12px 14px;background:{_AMARILLO_CLARO};
                  border-left:4px solid {_AMARILLO};border-radius:6px;
                  font-size:14px;color:{_AMARILLO_TEXTO};">
          <strong>No compartas este código con nadie.</strong> El equipo de AgeCare
          nunca te lo pedirá por teléfono, mensaje ni correo.
        </p>
    """

    html = _marco(titulo_pestana="Recupera tu contraseña — AgeCare", cuerpo=cuerpo)

    cfg = get_email_settings()
    legales = []
    if cfg.email_terms_url:
        legales.append(f"Términos y condiciones: {cfg.email_terms_url}")
    if cfg.email_privacy_url:
        legales.append(f"Política de privacidad: {cfg.email_privacy_url}")
    texto = (
        f"{'Hola, ' + nombre + '.' if nombre else 'Hola.'}\n\n"
        "Recibimos una solicitud para restablecer la contraseña de tu cuenta "
        "de AgeCare.\n\n"
        f"Tu código es: {codigo_legible}\n\n"
        f"Vence en {minutos} minutos y admite {intentos} intentos.\n"
        "No compartas este código con nadie. El equipo de AgeCare nunca te lo "
        "pedirá.\n\n"
        "Si no fuiste tú, ignora este mensaje.\n\n"
        + ("\n".join(legales) + "\n\n" if legales else "")
        + "— AgeCare"
    )
    return "Tu código para recuperar tu contraseña de AgeCare", html, texto

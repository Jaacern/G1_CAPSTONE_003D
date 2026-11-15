/// Nombres de los idiomas a partir del código ISO 639-1 de dos letras.
///
/// `caregiver_languages.language_code` guarda solo las dos letras y la ficha
/// del marketplace devuelve esa lista sin traducir, así que 'es' llegaría a
/// pantalla tal cual. El mapa cubre los idiomas que se esperan en el catálogo
/// del perfil de cuidadora; cualquier otro valor se devuelve sin cambiar, de
/// modo que un dato ya escrito en español (o un código nuevo) no se pierda.
library;

const Map<String, String> _nombresIdiomas = {
  'es': 'Español',
  'en': 'Inglés',
  'pt': 'Portugués',
  'fr': 'Francés',
  'it': 'Italiano',
  'de': 'Alemán',
  'qu': 'Quechua',
  'ay': 'Aymara',
};

/// El nombre del idioma, o el valor recibido si no es un código conocido.
String nombreIdioma(String codigo) =>
    _nombresIdiomas[codigo.toLowerCase()] ?? codigo;

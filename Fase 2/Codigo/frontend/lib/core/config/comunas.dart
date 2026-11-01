/// Nombres de las comunas a partir del código territorial.
///
/// El backend guarda solo el código de cinco dígitos (`caregiver_zones.
/// commune_code`, `job_offers.commune_code`) y en las respuestas devuelve ese
/// código, así que la aplicación es la que lo traduce; mostrar "08110" en la
/// ficha de una cuidadora no le sirve a nadie para elegir.
///
/// La lista cubre la provincia de Concepción (códigos 081xx), que es donde
/// están los perfiles y las ofertas que trae el juego de datos de desarrollo.
/// [nombreComuna] devuelve el código tal cual cuando no está en la tabla, así
/// que agregar más provincias después es solo añadir filas aquí.
library;

const Map<String, String> _nombresComunas = {
  '08101': 'Concepción',
  '08102': 'Coronel',
  '08103': 'Chiguayante',
  '08104': 'Florida',
  '08105': 'Hualqui',
  '08106': 'Lota',
  '08107': 'Penco',
  '08108': 'San Pedro de la Paz',
  '08109': 'Santa Juana',
  '08110': 'Talcahuano',
};

/// El nombre de la comuna, o el código mismo si no se conoce.
String nombreComuna(String codigo) => _nombresComunas[codigo] ?? codigo;

/// Código y nombre de cada comuna conocida, en orden de código.
List<(String, String)> get comunasConocidas =>
    List.unmodifiable(_nombresComunas.entries.map((e) => (e.key, e.value)));

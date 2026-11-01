/// Nombres de las comunas a partir del código territorial.
///
/// El backend guarda solo el código de cinco dígitos (`caregiver_zones.
/// commune_code`, `job_offers.commune_code`) y en las respuestas devuelve ese
/// código, así que la aplicación es la que lo traduce; mostrar "08110" en la
/// ficha de una cuidadora no le sirve a nadie para elegir.
///
/// Las parejas están en orden de código porque así quedan agrupadas por
/// provincia, que es como las devuelven las consultas.
///
/// [nombreComuna] devuelve el código tal cual cuando no está en la tabla, así
/// que cubrir más provincias después es solo añadir filas aquí.
library;

const Map<String, String> _nombresComunas = {
  // Región del Biobío (08), provincia de Concepción (081). Es donde están los
  // perfiles y las ofertas del juego de datos de desarrollo del backend.
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
  // Región Metropolitana (13), provincia de Santiago (131).
  '13101': 'Santiago',
  '13102': 'Cerrillos',
  '13103': 'Cerro Navia',
  '13104': 'Conchalí',
  '13105': 'El Bosque',
  '13106': 'Estación Central',
  '13107': 'Huechuraba',
  '13108': 'Independencia',
  '13109': 'La Cisterna',
  '13110': 'La Florida',
  '13111': 'La Granja',
  '13112': 'La Pintana',
  '13113': 'La Reina',
  '13114': 'Las Condes',
  '13115': 'Lo Barnechea',
  '13116': 'Lo Espejo',
  '13117': 'Lo Prado',
  '13118': 'Macul',
  '13119': 'Maipú',
  '13120': 'Ñuñoa',
  '13121': 'Pedro Aguirre Cerda',
  '13122': 'Peñalolén',
  '13123': 'Providencia',
  '13124': 'Pudahuel',
  '13125': 'Quilicura',
  '13126': 'Quinta Normal',
  '13127': 'Recoleta',
  '13128': 'Renca',
  '13129': 'San Joaquín',
  '13130': 'San Miguel',
  '13131': 'San Ramón',
  '13132': 'Vitacura',
};

/// El nombre de la comuna, o el código mismo si no se conoce.
String nombreComuna(String codigo) => _nombresComunas[codigo] ?? codigo;

/// Código y nombre de cada comuna conocida, en orden de código.
List<(String, String)> get comunasConocidas =>
    List.unmodifiable(_nombresComunas.entries.map((e) => (e.key, e.value)));

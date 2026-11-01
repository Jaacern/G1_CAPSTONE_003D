/// Modelos del Marketplace: cuidadoras, productos/ayudas técnicas, ofertas de
/// trabajo y reseñas. JSON en snake_case, fechas ISO8601.
library;

import 'package:intl/intl.dart';

/// Plata con el separador de miles chileno y sin decimales.
///
/// La API manda el monto como número y la moneda como código de tres letras;
/// un `toStringAsFixed(0)` dejaba la tarifa de una hora en "$12000", que en
/// pesos se lee mal. La que no es CLP conserva el código delante, porque un
/// símbolo de peso suelto no alcanza para saber en qué moneda es el precio.
String _plata(num monto, String moneda) {
  final numero = NumberFormat('#,##0', 'es').format(monto);
  return moneda == 'CLP' ? '\$$numero' : '$moneda $numero';
}

/// CLP es el supuesto de la tabla (`currency` tiene ese valor por defecto) y
/// el único que la API puede significar hoy: el listado de cuidadoras no
/// devuelve el código de moneda, solo el monto.
const String _monedaPadron = 'CLP';

/// Resumen de perfil de cuidadora para el listado.
class CaregiverProfileSummary {
  const CaregiverProfileSummary({
    required this.profileId,
    required this.name,
    this.photoUrl,
    required this.headline,
    required this.rating,
    required this.reviewsCount,
    this.zones = const [],
    this.specialties = const [],
    this.pricePerHour,
  });

  final String profileId;
  final String name;
  final String? photoUrl;
  final String headline;
  final double rating;
  final int reviewsCount;
  final List<String> zones;
  final List<String> specialties;
  final double? pricePerHour;

  /// 'Tarifa por hora' ya formateada, o null si la cuidadora no la publica.
  String? get tarifaLabel =>
      pricePerHour == null ? null : _plata(pricePerHour!, _monedaPadron);

  factory CaregiverProfileSummary.fromJson(Map<String, dynamic> json) =>
      CaregiverProfileSummary(
        profileId: json['profile_id'] as String,
        name: json['name'] as String,
        photoUrl: json['photo_url'] as String?,
        headline: (json['headline'] ?? '') as String,
        rating: (json['rating'] as num?)?.toDouble() ?? 0,
        reviewsCount: (json['reviews_count'] ?? 0) as int,
        zones:
            ((json['zones'] ?? []) as List).map((e) => e.toString()).toList(),
        specialties: ((json['specialties'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        pricePerHour: (json['price_per_hour'] as num?)?.toDouble(),
      );
}

/// Detalle completo de un perfil de cuidadora.
class CaregiverProfileDetail {
  const CaregiverProfileDetail({
    required this.profileId,
    required this.name,
    this.photoUrl,
    required this.headline,
    required this.rating,
    required this.reviewsCount,
    this.zones = const [],
    this.specialties = const [],
    this.pricePerHour,
    required this.bio,
    required this.yearsExperience,
    this.languages = const [],
    this.certifications = const [],
    this.reviews = const [],
  });

  final String profileId;
  final String name;
  final String? photoUrl;
  final String headline;
  final double rating;
  final int reviewsCount;
  final List<String> zones;
  final List<String> specialties;
  final double? pricePerHour;
  final String bio;
  final int yearsExperience;
  final List<String> languages;
  final List<String> certifications;
  final List<Review> reviews;

  /// 'Tarifa por hora' ya formateada, o null si la cuidadora no la publica.
  String? get tarifaLabel =>
      pricePerHour == null ? null : _plata(pricePerHour!, _monedaPadron);

  factory CaregiverProfileDetail.fromJson(Map<String, dynamic> json) =>
      CaregiverProfileDetail(
        profileId: json['profile_id'] as String,
        name: json['name'] as String,
        photoUrl: json['photo_url'] as String?,
        headline: (json['headline'] ?? '') as String,
        rating: (json['rating'] as num?)?.toDouble() ?? 0,
        reviewsCount: (json['reviews_count'] ?? 0) as int,
        zones:
            ((json['zones'] ?? []) as List).map((e) => e.toString()).toList(),
        specialties: ((json['specialties'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        pricePerHour: (json['price_per_hour'] as num?)?.toDouble(),
        bio: (json['bio'] ?? '') as String,
        yearsExperience: (json['years_experience'] ?? 0) as int,
        languages: ((json['languages'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        certifications: ((json['certifications'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        reviews: ((json['reviews'] ?? []) as List)
            .map((e) => Review.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Reseña de una cuidadora.
class Review {
  const Review({
    required this.authorName,
    required this.rating,
    required this.comment,
    required this.createdAt,
  });

  final String authorName;
  final int rating;
  final String comment;
  final DateTime createdAt;

  factory Review.fromJson(Map<String, dynamic> json) => Review(
        authorName: (json['author_name'] ?? 'Anónimo') as String,
        rating: (json['rating'] ?? 0) as int,
        comment: (json['comment'] ?? '') as String,
        // /caregivers/{id} devuelve la hora con su desplazamiento y
        // DateTime.parse la deja en UTC; sin toLocal la reseña aparecería con
        // la hora del servidor y, pasada la medianoche local, con otro día.
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String).toLocal()
            : DateTime.now(),
      );
}

/// Producto o ayuda técnica del marketplace.
class MarketProduct {
  const MarketProduct({
    required this.id,
    required this.name,
    this.imageUrl,
    required this.price,
    this.currency = _monedaPadron,
    required this.category,
    required this.description,
  });

  final String id;
  final String name;
  final String? imageUrl;
  final double price;

  /// Código ISO de tres letras, como lo guarda `market_products.currency`.
  final String currency;
  final String category;
  final String description;

  /// Precio listo para imprimir, con el separador de miles y la moneda.
  String get precioLabel => _plata(price, currency);

  factory MarketProduct.fromJson(Map<String, dynamic> json) => MarketProduct(
        id: json['id'] as String,
        name: json['name'] as String,
        imageUrl: json['image_url'] as String?,
        price: (json['price'] as num?)?.toDouble() ?? 0,
        currency: ((json['currency'] ?? _monedaPadron) as String).toUpperCase(),
        category: (json['category'] ?? 'other') as String,
        description: (json['description'] ?? '') as String,
      );
}

/// Oferta de trabajo para cuidadoras.
class JobOffer {
  const JobOffer({
    required this.id,
    required this.title,
    required this.zone,
    required this.pay,
    required this.description,
  });

  final String id;
  final String title;
  final String zone;
  final String pay;
  final String description;

  factory JobOffer.fromJson(Map<String, dynamic> json) => JobOffer(
        id: json['id'] as String,
        title: json['title'] as String,
        zone: (json['zone'] ?? '') as String,
        pay: (json['pay'] ?? '') as String,
        description: (json['description'] ?? '') as String,
      );
}

// ---------------------------------------------------------------------------
// Categorías del catálogo
// ---------------------------------------------------------------------------

/// Las siete categorías que acepta `GET /marketplace/products?category=`.
///
/// Son códigos en inglés y cualquier otro valor devuelve 422, así que la
/// pantalla pinta la etiqueta en español pero manda siempre la clave.
const Map<String, String> _categoriasProducto = {
  'mobility': 'Movilidad',
  'bathroom': 'Baño',
  'bedroom': 'Dormitorio',
  'hygiene': 'Higiene',
  'monitoring': 'Monitoreo',
  'nutrition': 'Nutrición',
  'other': 'Otros',
};

/// Etiqueta en español de una categoría; si llega un valor desconocido se
/// muestra el código, que es más honesto que un "Otros" inventado.
String categoriaProducto(String? codigo) {
  if (codigo == null || codigo.isEmpty) return 'Sin categoría';
  return _categoriasProducto[codigo] ?? codigo;
}

/// Clave y etiqueta de cada categoría, en el orden en que se muestran los
/// filtros.
List<(String, String)> get categoriasProducto =>
    List.unmodifiable(_categoriasProducto.entries.map((e) => (e.key, e.value)));

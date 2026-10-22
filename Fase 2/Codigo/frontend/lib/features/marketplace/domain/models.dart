/// Modelos del Marketplace: cuidadoras, productos/ayudas técnicas, ofertas de
/// trabajo y reseñas. JSON en snake_case, fechas ISO8601.

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
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
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
    required this.category,
    required this.description,
  });

  final String id;
  final String name;
  final String? imageUrl;
  final double price;
  final String category;
  final String description;

  factory MarketProduct.fromJson(Map<String, dynamic> json) => MarketProduct(
        id: json['id'] as String,
        name: json['name'] as String,
        imageUrl: json['image_url'] as String?,
        price: (json['price'] as num?)?.toDouble() ?? 0,
        category: (json['category'] ?? 'general') as String,
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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

abstract class MarketplaceRepository {
  Future<List<CaregiverProfileSummary>> listCaregivers({
    String? zone,
    String? specialty,
  });
  Future<CaregiverProfileDetail> getCaregiver(String profileId);
  Future<void> contact(String profileId, String message);
  Future<void> addReview(String profileId,
      {required int rating, required String comment});
  Future<List<MarketProduct>> listProducts({String? category});
  Future<MarketProduct> getProduct(String id);
  Future<List<JobOffer>> listJobs();
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class MarketplaceRepositoryHttp implements MarketplaceRepository {
  MarketplaceRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<CaregiverProfileSummary>> listCaregivers({
    String? zone,
    String? specialty,
  }) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/marketplace/caregivers',
      query: {
        if (zone != null && zone.isNotEmpty) 'zone': zone,
        if (specialty != null && specialty.isNotEmpty) 'specialty': specialty,
      },
    );
    return ((data['items'] ?? []) as List)
        .map((e) => CaregiverProfileSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<CaregiverProfileDetail> getCaregiver(String profileId) async {
    final res = await _api
        .get<Map<String, dynamic>>('/marketplace/caregivers/$profileId');
    return CaregiverProfileDetail.fromJson(res);
  }

  @override
  Future<void> contact(String profileId, String message) => _api.post<void>(
        '/marketplace/caregivers/$profileId/contact',
        data: {'message': message},
      );

  @override
  Future<void> addReview(String profileId,
          {required int rating, required String comment}) =>
      _api.post<void>(
        '/marketplace/caregivers/$profileId/reviews',
        data: {'rating': rating, 'comment': comment},
      );

  @override
  Future<List<MarketProduct>> listProducts({String? category}) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/marketplace/products',
      query: {
        if (category != null && category.isNotEmpty) 'category': category,
      },
    );
    return ((data['items'] ?? []) as List)
        .map((e) => MarketProduct.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<MarketProduct> getProduct(String id) async {
    final res =
        await _api.get<Map<String, dynamic>>('/marketplace/products/$id');
    return MarketProduct.fromJson(res);
  }

  @override
  Future<List<JobOffer>> listJobs() async {
    final data = await _api.get<Map<String, dynamic>>('/jobs');
    return ((data['items'] ?? []) as List)
        .map((e) => JobOffer.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class MarketplaceRepositoryMock implements MarketplaceRepository {
  MarketplaceRepositoryMock() {
    _seed();
  }

  final List<CaregiverProfileSummary> _caregivers = [];
  final Map<String, List<Review>> _reviews = {};
  final List<MarketProduct> _products = [];
  final List<JobOffer> _jobs = [];

  void _seed() {
    _caregivers.addAll([
      const CaregiverProfileSummary(
        profileId: 'cg-1',
        name: 'María González',
        photoUrl: null,
        headline: 'Cuidadora certificada · 8 años de experiencia',
        rating: 4.8,
        reviewsCount: 34,
        zones: ['08101', '08103', '08108'],
        specialties: ['Alzheimer', 'Movilidad reducida', 'Postoperatorio'],
        pricePerHour: 12000,
      ),
      const CaregiverProfileSummary(
        profileId: 'cg-2',
        name: 'Rosa Hernández',
        photoUrl: null,
        headline: 'Enfermera geriátrica · Nocturnos disponibles',
        rating: 4.6,
        reviewsCount: 21,
        zones: ['13120', '13123', '13114'],
        specialties: ['Diabetes', 'Control de medicación', 'Curaciones'],
        pricePerHour: 15000,
      ),
      const CaregiverProfileSummary(
        profileId: 'cg-3',
        name: 'Laura Jiménez',
        photoUrl: null,
        headline: 'Acompañamiento y estimulación cognitiva',
        rating: 4.9,
        reviewsCount: 52,
        zones: ['13119', '13105'],
        specialties: ['Estimulación cognitiva', 'Acompañamiento', 'Parkinson'],
        pricePerHour: 11000,
      ),
    ]);

    _reviews['cg-1'] = [
      Review(
        authorName: 'Familia Ramírez',
        rating: 5,
        comment: 'Muy atenta y puntual. Mi mamá la quiere mucho.',
        createdAt: DateTime.now().subtract(const Duration(days: 12)),
      ),
      Review(
        authorName: 'Jorge M.',
        rating: 4,
        comment: 'Buen trato y profesional. Recomendada.',
        createdAt: DateTime.now().subtract(const Duration(days: 40)),
      ),
    ];
    _reviews['cg-2'] = [
      Review(
        authorName: 'Ana P.',
        rating: 5,
        comment: 'Excelente manejo de la medicación y curaciones.',
        createdAt: DateTime.now().subtract(const Duration(days: 20)),
      ),
    ];
    _reviews['cg-3'] = [
      Review(
        authorName: 'Familia Torres',
        rating: 5,
        comment: 'Las actividades de estimulación han ayudado muchísimo.',
        createdAt: DateTime.now().subtract(const Duration(days: 8)),
      ),
    ];

    // Mismo catálogo que siembra el backend (sql/925_market_products.sql), con
    // sus precios en pesos, para que la demo se vea como la API real.
    _products.addAll([
      const MarketProduct(
        id: 'p-andador',
        name: 'Andador plegable con ruedas',
        imageUrl: null,
        price: 45990,
        category: 'mobility',
        description:
            'Andador de aluminio con dos ruedas delanteras y regulación de '
            'altura. Soporta hasta 100 kg y se pliega para guardarlo o '
            'llevarlo en auto.',
      ),
      const MarketProduct(
        id: 'p-silla-ruedas',
        name: 'Silla de ruedas estándar',
        imageUrl: null,
        price: 139990,
        category: 'mobility',
        description:
            'Silla plegable de acero con apoyapiés desmontables y frenos en '
            'ambas ruedas. Para uso domiciliario y traslados cortos.',
      ),
      const MarketProduct(
        id: 'p-barra-ducha',
        name: 'Barra de apoyo para ducha',
        imageUrl: null,
        price: 18990,
        category: 'bathroom',
        description:
            'Barra de sujeción de 60 cm con ventosas de presión, para instalar '
            'sin perforar. Reduce el riesgo de caída en el baño, que es donde '
            'más ocurren.',
      ),
      const MarketProduct(
        id: 'p-silla-ducha',
        name: 'Silla de ducha con respaldo',
        imageUrl: null,
        price: 32990,
        category: 'bathroom',
        description:
            'Asiento plástico con patas antideslizantes y altura regulable, '
            'para quienes no pueden mantenerse de pie durante el baño.',
      ),
      const MarketProduct(
        id: 'p-panales',
        name: 'Pañales para adulto, talla M',
        imageUrl: null,
        price: 12990,
        category: 'hygiene',
        description:
            'Paquete de 20 unidades con alta absorción y banda elástica. '
            'Talla M, contorno de cadera 80 a 120 cm.',
      ),
      const MarketProduct(
        id: 'p-pastillero',
        name: 'Pastillero semanal con alarma',
        imageUrl: null,
        price: 24990,
        category: 'monitoring',
        description:
            'Organizador de 7 días con 4 tomas diarias y alarma sonora '
            'programable, para no saltarse ni repetir una dosis.',
      ),
    ]);

    _jobs.addAll([
      const JobOffer(
        id: 'j-1',
        title: 'Cuidadora de día para adulto mayor',
        zone: '08101',
        pay: '\$550.000 - \$650.000 / mes',
        description:
            'Se busca cuidadora para acompañamiento diurno (L-V, 8:00 a 16:00) '
            'de señora de 78 años con movilidad reducida. Experiencia comprobable.',
      ),
      const JobOffer(
        id: 'j-2',
        title: 'Enfermera para turnos nocturnos',
        zone: '13120',
        pay: '\$80.000 / noche',
        description:
            'Turnos nocturnos para administración de medicamentos y monitoreo '
            'de paciente postoperatorio. Se valora título con registro en la '
            'Superintendencia de Salud.',
      ),
    ]);
  }

  double _avg(List<Review> reviews) {
    if (reviews.isEmpty) return 0;
    return reviews.map((r) => r.rating).reduce((a, b) => a + b) /
        reviews.length;
  }

  @override
  Future<List<CaregiverProfileSummary>> listCaregivers({
    String? zone,
    String? specialty,
  }) async {
    await Future.delayed(const Duration(milliseconds: 350));
    return _caregivers.where((c) {
      final okZone = zone == null ||
          zone.isEmpty ||
          c.zones.any((z) => z.toLowerCase().contains(zone.toLowerCase()));
      final okSpec = specialty == null ||
          specialty.isEmpty ||
          c.specialties
              .any((s) => s.toLowerCase().contains(specialty.toLowerCase()));
      return okZone && okSpec;
    }).toList();
  }

  @override
  Future<CaregiverProfileDetail> getCaregiver(String profileId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final c = _caregivers.firstWhere(
      (e) => e.profileId == profileId,
      orElse: () => throw ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'El perfil solicitado no existe.',
      ),
    );
    final reviews = _reviews[profileId] ?? const <Review>[];
    return CaregiverProfileDetail(
      profileId: c.profileId,
      name: c.name,
      photoUrl: c.photoUrl,
      headline: c.headline,
      rating: reviews.isEmpty ? c.rating : _avg(reviews),
      reviewsCount: reviews.length,
      zones: c.zones,
      specialties: c.specialties,
      pricePerHour: c.pricePerHour,
      bio: 'Soy ${c.name}, cuidadora con vocación de servicio. Me dedico al '
          'cuidado de adultos mayores con paciencia, cariño y responsabilidad. '
          'Ofrezco apoyo en actividades diarias, higiene, alimentación y '
          'acompañamiento.',
      yearsExperience: 8,
      languages: const ['es', 'en'],
      certifications: const [
        'Certificado en cuidados geriátricos',
        'Primeros auxilios y RCP',
      ],
      reviews: reviews,
    );
  }

  @override
  Future<void> contact(String profileId, String message) async {
    await Future.delayed(const Duration(milliseconds: 350));
  }

  @override
  Future<void> addReview(String profileId,
      {required int rating, required String comment}) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final list = _reviews.putIfAbsent(profileId, () => []);
    list.insert(
      0,
      Review(
        authorName: 'Tú',
        rating: rating,
        comment: comment,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<List<MarketProduct>> listProducts({String? category}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (category == null || category.isEmpty) return List.of(_products);
    return _products.where((p) => p.category == category).toList();
  }

  @override
  Future<MarketProduct> getProduct(String id) async {
    await Future.delayed(const Duration(milliseconds: 250));
    return _products.firstWhere(
      (p) => p.id == id,
      orElse: () => throw ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'El producto solicitado no existe.',
      ),
    );
  }

  @override
  Future<List<JobOffer>> listJobs() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return List.of(_jobs);
  }
}

final marketplaceRepositoryProvider = Provider<MarketplaceRepository>((ref) {
  if (AppConfig.useMocks) return MarketplaceRepositoryMock();
  return MarketplaceRepositoryHttp(ref.watch(apiClientProvider));
});

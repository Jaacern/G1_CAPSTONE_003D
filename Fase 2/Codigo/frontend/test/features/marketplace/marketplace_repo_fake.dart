import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/marketplace/data/marketplace_repository.dart';
import 'package:agecare_app/features/marketplace/domain/models.dart';
import 'package:agecare_app/features/marketplace/presentation/marketplace_screen.dart';

/// Repositorio del marketplace para pruebas de pantalla: no llama a la API y
/// anota con qué argumentos lo invitaron a filtrar.
class MarketplaceRepoFake implements MarketplaceRepository {
  String? zonaEnviada;
  String? categoriaEnviada;

  /// Las ofertas que la pantalla de trabajos va a ver. Se pueden reemplazar
  /// antes de montar la vista.
  List<JobOffer> ofertas = const [
    JobOffer(
      id: 'j-9',
      title: 'Cuidadora de día',
      zone: '08101',
      pay: '\$600.000 / mes',
      description: 'Acompañamiento diurno.',
    ),
  ];

  /// Las cuidadoras que devuelve el listado, para probar la tarjeta con
  /// nombres y especialidades largas.
  List<CaregiverProfileSummary> cuidadoras = const [];

  /// El catálogo que devuelve la tira de productos, filtrado por categoría
  /// igual que hace la API.
  List<MarketProduct> productos = const [
    MarketProduct(
      id: 'p-silla-ruedas',
      name: 'Silla de ruedas estándar',
      price: 139990,
      category: 'mobility',
      description:
          'Silla plegable de acero con apoyapiés desmontables y frenos en '
          'ambas ruedas. Para uso domiciliario y traslados cortos.',
    ),
    MarketProduct(
      id: 'p-pastillero',
      name: 'Pastillero semanal con alarma',
      price: 24990,
      category: 'monitoring',
      description:
          'Organizador de 7 días con 4 tomas diarias y alarma sonora '
          'programable, para no saltarse ni repetir una dosis.',
    ),
  ];

  @override
  Future<List<CaregiverProfileSummary>> listCaregivers({
    String? zone,
    String? specialty,
  }) async {
    zonaEnviada = zone;
    return cuidadoras;
  }

  @override
  Future<List<MarketProduct>> listProducts({String? category}) async {
    categoriaEnviada = category;
    if (category == null) return productos;
    return productos.where((p) => p.category == category).toList();
  }

  @override
  Future<List<JobOffer>> listJobs() async => ofertas;

  @override
  Future<CaregiverProfileDetail> getCaregiver(String profileId) =>
      throw UnimplementedError();

  @override
  Future<MarketProduct> getProduct(String id) => throw UnimplementedError();

  @override
  Future<void> contact(String profileId, String message) =>
      throw UnimplementedError();

  @override
  Future<void> addReview(String profileId,
          {required int rating, required String comment}) =>
      throw UnimplementedError();
}

/// Monta el marketplace como familiar (dos pestañas) o como cuidadora (tres)
/// y deja la primera visible. El listado de cuidadoras hay que darlo acá y no
/// después: la pantalla ya pide la lista en el primer frame.
Future<MarketplaceRepoFake> montarMarketplace(
  WidgetTester tester, {
  RoleType rol = RoleType.family,
  List<CaregiverProfileSummary> cuidadoras = const [],
}) async {
  final repo = MarketplaceRepoFake()..cuidadoras = cuidadoras;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      currentUserProvider.overrideWith(
        (ref) => User(
          userId: 'u-1',
          fullName: 'Benjamín Camus',
          email: 'familia@agecare.app',
          memberships: [
            Membership(
                patientId: 'p-1',
                patientName: 'Elena Ramírez',
                role: rol),
          ],
        ),
      ),
      marketplaceRepositoryProvider.overrideWithValue(repo),
    ],
    child: const MaterialApp(home: MarketplaceScreen()),
  ));
  await tester.pump();
  return repo;
}

/// El mismo montaje, pero en un teléfono de 320 dp de ancho. La letra que usa
/// el juego de pruebas es más ancha que la de la app: lo que cabe acá cabe
/// también con el texto grande del celular.
Future<MarketplaceRepoFake> montarMarketplaceEnTelefono(
  WidgetTester tester, {
  List<CaregiverProfileSummary> cuidadoras = const [],
}) async {
  tester.view.physicalSize = const Size(320 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return montarMarketplace(tester, cuidadoras: cuidadoras);
}

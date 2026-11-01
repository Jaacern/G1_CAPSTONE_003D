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

  @override
  Future<List<CaregiverProfileSummary>> listCaregivers({
    String? zone,
    String? specialty,
  }) async {
    zonaEnviada = zone;
    return const [];
  }

  @override
  Future<List<MarketProduct>> listProducts({String? category}) async {
    categoriaEnviada = category;
    return const [];
  }

  @override
  Future<List<JobOffer>> listJobs() async => const [];

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

/// Monta el marketplace como familiar (dos pestañas, sin trabajos) y deja la
/// primera visible.
Future<MarketplaceRepoFake> montarMarketplace(WidgetTester tester) async {
  final repo = MarketplaceRepoFake();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      currentUserProvider.overrideWith(
        (ref) => const User(
          userId: 'u-1',
          fullName: 'Benjamín Camus',
          email: 'familia@agecare.app',
          memberships: [
            Membership(
                patientId: 'p-1',
                patientName: 'Elena Ramírez',
                role: RoleType.family),
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

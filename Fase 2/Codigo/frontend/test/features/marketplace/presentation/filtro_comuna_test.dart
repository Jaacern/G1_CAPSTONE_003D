import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/marketplace/data/marketplace_repository.dart';
import 'package:agecare_app/features/marketplace/domain/models.dart';
import 'package:agecare_app/features/marketplace/presentation/marketplace_screen.dart';

/// Registra el código con el que la pantalla llamó a /marketplace/caregivers.
class _RepoFake implements MarketplaceRepository {
  String? zonaEnviada;

  @override
  Future<List<CaregiverProfileSummary>> listCaregivers({
    String? zone,
    String? specialty,
  }) async {
    zonaEnviada = zone;
    return const [];
  }

  @override
  Future<CaregiverProfileDetail> getCaregiver(String profileId) =>
      throw UnimplementedError();

  @override
  Future<void> contact(String profileId, String message) =>
      throw UnimplementedError();

  @override
  Future<void> addReview(String profileId,
          {required int rating, required String comment}) =>
      throw UnimplementedError();

  @override
  Future<List<MarketProduct>> listProducts({String? category}) async =>
      const [];

  @override
  Future<MarketProduct> getProduct(String id) => throw UnimplementedError();

  @override
  Future<List<JobOffer>> listJobs() async => const [];
}

Future<_RepoFake> _abrir(WidgetTester tester) async {
  final repo = _RepoFake();
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

void main() {
  testWidgets('la búsqueda ofrece comunas por nombre', (tester) async {
    await _abrir(tester);

    expect(find.text('Comuna'), findsOne);
    expect(find.text('Todas las comunas'), findsWidgets);
    expect(find.text('Concepción'), findsNothing);
  });

  testWidgets('elegir una comuna manda su código, no su nombre',
      (tester) async {
    final repo = await _abrir(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Concepción'), findsOne);

    await tester.tap(find.text('Concepción'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump();
    await tester.pump();

    expect(repo.zonaEnviada, '08101');
  });
}

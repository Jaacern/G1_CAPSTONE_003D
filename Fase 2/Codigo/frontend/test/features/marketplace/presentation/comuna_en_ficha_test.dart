import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:agecare_app/features/marketplace/application/marketplace_providers.dart';
import 'package:agecare_app/features/marketplace/domain/models.dart';
import 'package:agecare_app/features/marketplace/presentation/caregiver_profile_screen.dart';

/// La ficha se arma con el detalle que devuelve /marketplace/caregivers/{id},
/// donde `zones` son códigos territoriales y no nombres.
CaregiverProfileDetail _ficha() => CaregiverProfileDetail(
      profileId: 'cg-1',
      name: 'María González',
      headline: 'Cuidadora certificada',
      rating: 4.8,
      reviewsCount: 1,
      zones: const ['08101', '08110'],
      pricePerHour: 12000,
      bio: 'Cuidadora con experiencia.',
      yearsExperience: 8,
      reviews: [
        Review(
          authorName: 'Familia Ramírez',
          rating: 5,
          comment: 'Muy atenta.',
          createdAt: DateTime(2026, 10, 30, 20, 15),
        ),
      ],
    );

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  testWidgets('las zonas de la ficha se muestran con el nombre de la comuna',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        caregiverDetailProvider.overrideWith((_, __) async => _ficha()),
      ],
      child: const MaterialApp(
        home: CaregiverProfileScreen(profileId: 'cg-1'),
      ),
    ));
    await tester.pump();

    expect(find.text('Zonas: Concepción, Talcahuano'), findsOne);
    expect(find.textContaining('08101'), findsNothing);
  });

  testWidgets('una comuna que no está en la tabla no deja la fila vacía',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        caregiverDetailProvider.overrideWith(
          (_, __) async => const CaregiverProfileDetail(
            profileId: 'cg-2',
            name: 'Rosa Hernández',
            headline: 'Enfermera',
            rating: 4.6,
            reviewsCount: 0,
            zones: ['04101'],
            bio: '',
            yearsExperience: 5,
          ),
        ),
      ],
      child: const MaterialApp(
        home: CaregiverProfileScreen(profileId: 'cg-2'),
      ),
    ));
    await tester.pump();

    expect(find.text('Zonas: 04101'), findsOne);
  });
}

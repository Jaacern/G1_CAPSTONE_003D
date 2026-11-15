import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/marketplace/domain/models.dart';

import '../../marketplace/marketplace_repo_fake.dart';

/// Las tarjetas del marketplace en un teléfono de 320 dp de ancho. La letra del
/// juego de pruebas es más ancha que la de la app, así que lo que cabe acá cabe
/// también con el texto grande del celular.
void main() {
  testWidgets('la tarjeta de una cuidadora cabe en 320 dp', (tester) async {
    await montarMarketplaceEnTelefono(tester, cuidadoras: const [
      CaregiverProfileSummary(
        profileId: 'cg-9',
        name: 'Marcos Villarroel Andrade',
        headline: 'Cuidador certificado · 8 años de experiencia',
        rating: 4.8,
        reviewsCount: 34,
        zones: ['08101', '08103'],
        specialties: ['Alzheimer', 'Movilidad reducida', 'Postoperatorio'],
        pricePerHour: 12000,
      ),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('Marcos Villarroel Andrade'), findsOne);
    expect(find.text('\$12.000/h'), findsOne);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/auth/domain/models.dart';

import '../../marketplace/marketplace_repo_fake.dart';

/// La pestaña de trabajos, que sólo ve la cuidadora.
void main() {
  /// Igual que en las otras pestañas: hay que dejar terminar la animación del
  /// cambio de tab o el `tap` cae sobre una página todavía ignorada.
  Future<void> irATrabajos(WidgetTester tester) async {
    await tester.tap(find.text('Trabajos'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('la oferta traduce el código territorial de la comuna',
      (tester) async {
    await montarMarketplace(tester, rol: RoleType.caregiver);
    await irATrabajos(tester);

    expect(find.text('Cuidadora de día'), findsOne);
    expect(find.text('Concepción'), findsOne);
    expect(find.textContaining('08101'), findsNothing);
  });
}

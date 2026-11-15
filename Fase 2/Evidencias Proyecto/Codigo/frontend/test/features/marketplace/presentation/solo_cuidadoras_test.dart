// El marketplace muestra solo cuidadoras: la venta de productos se saco por
// decision del equipo.
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../marketplace_repo_fake.dart';

void main() {
  testWidgets('el familiar ve la busqueda de cuidadoras, sin pestanas',
      (tester) async {
    await montarMarketplace(tester);

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Productos'), findsNothing);
    expect(find.text('Especialidad'), findsOneWidget);
  });

  testWidgets('la cuidadora ve cuidadoras y sus ofertas de trabajo',
      (tester) async {
    await montarMarketplace(tester, rol: RoleType.caregiver);

    expect(find.text('Cuidadoras'), findsOneWidget);
    expect(find.text('Trabajos'), findsOneWidget);
    expect(find.text('Productos'), findsNothing);
  });
}

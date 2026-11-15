import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/marketplace/presentation/marketplace_screen.dart';

import '../../marketplace/marketplace_repo_fake.dart';

void main() {
  testWidgets('la búsqueda ofrece comunas por nombre', (tester) async {
    await montarMarketplace(tester);

    expect(find.text('Comuna'), findsOne);
    expect(find.text('Todas las comunas'), findsWidgets);
    expect(find.text('Concepción'), findsNothing);
  });

  testWidgets('elegir una comuna manda su código, no su nombre',
      (tester) async {
    final repo = await montarMarketplace(tester);

    await tester.tap(
        find.descendant(
            of: find.byType(MarketplaceScreen),
            matching: find.byType(DropdownButtonFormField<String>)));
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

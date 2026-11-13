import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../marketplace/marketplace_repo_fake.dart';

/// La pestaña de productos muestra el catálogo completo, sin categorías.
///
/// El equipo decidió quitar la categoría de la tienda: ni la tira de filtros
/// de arriba ni la etiqueta en cada tarjeta. Estas pruebas cuidan que no
/// vuelvan por accidente.
void main() {
  /// El cambio de pestaña anima 300 ms y mientras no termina, la página nueva
  /// está bajo `IgnorePointer`: un `tap` ahí no llega a ningún sitio. Al final
  /// tampoco se puede `pumpAndSettle`, porque el spinner de carga no termina.
  Future<void> irAProductos(WidgetTester tester) async {
    await tester.tap(find.text('Productos'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('no hay filtros por categoría', (tester) async {
    await montarMarketplace(tester);
    await irAProductos(tester);

    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('pide el catálogo completo, sin mandar categoría',
      (tester) async {
    final repo = await montarMarketplace(tester);
    await irAProductos(tester);

    expect(repo.categoriaEnviada, isNull);
  });

  testWidgets('cada producto muestra nombre y precio, sin su categoría',
      (tester) async {
    await montarMarketplace(tester);
    await irAProductos(tester);

    expect(find.text('Silla de ruedas estándar'), findsOne);
    expect(find.text('\$139.990'), findsOne);
    expect(find.text('Movilidad'), findsNothing);
    expect(find.text('Monitoreo'), findsNothing);
  });
}

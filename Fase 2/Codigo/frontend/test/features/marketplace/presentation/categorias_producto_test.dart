import 'package:flutter_test/flutter_test.dart';

import '../../marketplace/marketplace_repo_fake.dart';

/// Filtro por categoría en la pestaña de productos.
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

  testWidgets('los chips que caben en pantalla salen del backend',
      (tester) async {
    await montarMarketplace(tester);
    await irAProductos(tester);

    // La tira es un ListView horizontal y perezoso: sólo construye los chips
    // que caben, así que 'Nutrición' y 'Otros' se prueban en el dominio.
    for (final etiqueta in [
      'Todas',
      'Movilidad',
      'Baño',
      'Dormitorio',
      'Higiene',
    ]) {
      expect(find.text(etiqueta), findsOne, reason: 'falta $etiqueta');
    }
  });

  testWidgets('elegir una categoría filtra con su código', (tester) async {
    final repo = await montarMarketplace(tester);
    await irAProductos(tester);

    await tester.tap(find.text('Baño'));
    await tester.pump();
    await tester.pump();

    expect(repo.categoriaEnviada, 'bathroom');
  });

  testWidgets('una categoría vacía lo dice, en vez de negar el catálogo',
      (tester) async {
    await montarMarketplace(tester);
    await irAProductos(tester);

    await tester.tap(find.text('Dormitorio'));
    await tester.pump();
    await tester.pump();

    expect(find.text('No hay productos en Dormitorio.'), findsOne);
  });
}

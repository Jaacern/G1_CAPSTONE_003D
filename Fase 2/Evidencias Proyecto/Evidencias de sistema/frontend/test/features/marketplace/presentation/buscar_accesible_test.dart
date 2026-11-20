// El boton de buscar cuidadoras es solo una lupa: sin nombre, el lector de
// pantalla lo anunciaba como "boton".
import 'package:flutter_test/flutter_test.dart';

import '../marketplace_repo_fake.dart';

void main() {
  testWidgets('el boton de buscar tiene nombre para el lector de pantalla',
      (tester) async {
    await montarMarketplace(tester);

    expect(find.byTooltip('Buscar'), findsOneWidget);
  });
}

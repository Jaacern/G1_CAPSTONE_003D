// La barra inferior del rol familiar tiene cinco destinos. En un teléfono de
// 360 dp cada destino dispone de ~72 dp y "Comunicación" se dibujaba cortada con
// puntos suspensivos.
//
// No se puede medir el ancho real con TextPainter en un test: flutter_test usa
// la fuente FlutterTest (Ahem), que mide ~14 dp por glifo contra los ~7 dp de
// Roboto, y todo etiqueta saldría ancha de más. Se comprueba el presupuesto de
// caracteres del destino, que es independiente de la fuente del test.
import 'package:agecare_app/features/shell/main_shell.dart';
import 'package:flutter_test/flutter_test.dart';

const _screenWidth = 360.0;

/// Ancho medio de un glifo en `labelLarge` (12 sp) con Roboto, en dp. Es un
/// promedio conservador: las vocales y las consonantes anchas suben poco más.
const _dpPerChar = 7.0;

/// Máximo de caracteres que caben en cada destino de la barra de [tabs].
int _presupuesto(List<ShellTab> tabs) =>
    ((_screenWidth / tabs.length) / _dpPerChar).floor();

void _expectCaben(List<ShellTab> tabs) {
  final maximo = _presupuesto(tabs);
  for (final t in tabs) {
    expect(t.label.length, lessThanOrEqualTo(maximo),
        reason: '"${t.label}" tiene ${t.label.length} caracteres y el destino '
            'de una barra de ${tabs.length} en ${_screenWidth.toInt()} dp '
            'admite $maximo: se recorta con elipsis.');
  }
}

void main() {
  test('la barra familiar cabe en 360 dp',
      () => _expectCaben(MainShell.familyTabs));
  test('la barra de la cuidadora cabe en 360 dp',
      () => _expectCaben(MainShell.caregiverTabs));
  test('la barra del médico cabe en 360 dp',
      () => _expectCaben(MainShell.doctorTabs));

  test('un nombre completo solo existe si la etiqueta es un acortado', () {
    for (final t in [
      ...MainShell.familyTabs,
      ...MainShell.caregiverTabs,
      ...MainShell.doctorTabs
    ]) {
      if (t.full != null) {
        expect(t.full, isNot(t.label),
            reason: '"${t.label}" duplica su nombre completo: [full] sobra y '
                'el tooltip quedaría igual que la etiqueta.');
      }
    }
  });
}

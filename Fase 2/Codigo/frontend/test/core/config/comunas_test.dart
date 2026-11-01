import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/config/comunas.dart';

void main() {
  group('nombreComuna', () {
    test('traduce los códigos que usan los datos de desarrollo', () {
      expect(nombreComuna('08101'), 'Concepción');
      expect(nombreComuna('08110'), 'Talcahuano');
    });

    test('traduce las comunas de la provincia de Santiago', () {
      expect(nombreComuna('13101'), 'Santiago');
      expect(nombreComuna('13123'), 'Providencia');
      expect(nombreComuna('13132'), 'Vitacura');
    });

    test('un código que no está en la tabla se muestra tal cual', () {
      expect(nombreComuna('04101'), '04101');
    });

    test('no confunde el código con una comuna vacía', () {
      expect(nombreComuna(''), '');
    });
  });

  group('comunasConocidas', () {
    test('los códigos tienen los cinco dígitos que exige el backend', () {
      for (final (codigo, _) in comunasConocidas) {
        expect(codigo, matches(RegExp(r'^[0-9]{5}$')));
      }
    });

    test('están ordenadas por código, como las devuelve la consulta', () {
      final codigos = comunasConocidas.map((c) => c.$1).toList();
      expect(codigos, orderedEquals([...codigos]..sort()));
    });

    test('ningún nombre queda vacío', () {
      for (final (_, nombre) in comunasConocidas) {
        expect(nombre, isNotEmpty);
      }
    });
  });
}

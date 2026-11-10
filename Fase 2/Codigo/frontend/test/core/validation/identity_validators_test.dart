import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/validation/identity_validators.dart';

/// Mismas reglas que backend/api/app/validators.py.
void main() {
  group('RUT', () {
    test('acepta con y sin puntos ni guion', () {
      expect(validateRut('5.123.456-1'), isNull);
      expect(validateRut('51234561'), isNull);
      expect(validateRut('12.345.678-5'), isNull);
    });

    test('acepta dígito K', () {
      // 10.000.013 tiene dígito K.
      expect(rutCheckDigit(10000013), 'K');
      expect(validateRut('10.000.013-k'), isNull);
    });

    test('rechaza dígito verificador malo', () {
      expect(
          validateRut('5.123.456-K'), 'El dígito verificador no corresponde');
    });

    test('rechaza formato inválido y vacío', () {
      expect(validateRut(''), 'Escribe el RUT');
      expect(validateRut('abc'), isNotNull);
    });

    test('formatea con puntos y guion', () {
      expect(formatRut('123456785'), '12.345.678-5');
      expect(formatRut('5123456-1'), '5.123.456-1');
    });
  });

  group('teléfono', () {
    test('normaliza a E.164', () {
      expect(normalizePhone('9 1234 5678'), '+56912345678');
      expect(normalizePhone('+56 9 1234-5678'), '+56912345678');
      expect(normalizePhone('56912345678'), '+56912345678');
    });

    test('rechaza números incompletos', () {
      expect(normalizePhone('123'), isNull);
      expect(validatePhone('123'), isNotNull);
      expect(validatePhone('', required: false), isNull);
    });
  });

  group('nombre', () {
    test('acepta tildes, ñ, apóstrofe y guion', () {
      expect(validatePersonName('María José'), isNull);
      expect(validatePersonName('Núñez'), isNull);
      expect(validatePersonName("O'Higgins"), isNull);
      expect(validatePersonName('Pérez-Cotapos'), isNull);
    });

    test('rechaza números y símbolos', () {
      expect(validatePersonName('1234'), isNotNull);
      expect(validatePersonName('<script>'), isNotNull);
      expect(validatePersonName('Ana2'), isNotNull);
    });

    test('opcional vacío no es error', () {
      expect(validatePersonName('', required: false), isNull);
      expect(validatePersonName('', campo: 'el nombre'), 'Escribe el nombre');
    });
  });
}

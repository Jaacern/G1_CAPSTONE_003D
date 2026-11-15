// La dosis como se lee en pantalla, y la limpieza del prefijo "Forma:" que
// una version anterior dejaba escrito dentro de las instrucciones.
import 'package:agecare_app/features/medications/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('etiquetaDeDosis', () {
    test('las unidades de medida no cambian con la cantidad', () {
      expect(etiquetaDeDosis('50', 'mg'), '50 mg');
      expect(etiquetaDeDosis('1', 'ml'), '1 ml');
      expect(etiquetaDeDosis('400', 'UI'), '400 UI');
    });

    test('las unidades que se cuentan concuerdan con el numero', () {
      expect(etiquetaDeDosis('1', 'comprimido'), '1 comprimido');
      expect(etiquetaDeDosis('2', 'comprimido'), '2 comprimidos');
      expect(etiquetaDeDosis('1', 'cápsula'), '1 cápsula');
      expect(etiquetaDeDosis('3', 'cápsula'), '3 cápsulas');
      expect(etiquetaDeDosis('1', 'parche'), '1 parche');
      expect(etiquetaDeDosis('2', 'parche'), '2 parches');
    });

    test("'gotas' llega en plural del backend pero una sola es 'gota'", () {
      // El CHECK de la base solo admite 'gotas', asi que ese es el valor
      // guardado; el singular es cosa de como se muestra.
      expect(etiquetaDeDosis('1', 'gotas'), '1 gota');
      expect(etiquetaDeDosis('10', 'gotas'), '10 gotas');
    });

    test("'puff' no se pluraliza en castellano", () {
      expect(etiquetaDeDosis('1', 'puff'), '1 puff');
      expect(etiquetaDeDosis('2', 'puff'), '2 puff');
    });

    test('el decimal del backend no se muestra cuando no aporta', () {
      // dose_amount es numeric(8,2), asi que llega como 50.0 y antes la
      // pantalla decia "50.0 mg".
      expect(etiquetaDeDosis('50.0', 'mg'), '50 mg');
      expect(etiquetaDeDosis('2.0', 'comprimido'), '2 comprimidos');
    });

    test('el decimal que si aporta se muestra con coma', () {
      expect(etiquetaDeDosis('2.5', 'ml'), '2,5 ml');
      expect(etiquetaDeDosis('0.5', 'comprimido'), '0,5 comprimidos');
    });

    test('acepta la coma decimal que escribe la gente', () {
      expect(etiquetaDeDosis('2,5', 'ml'), '2,5 ml');
    });

    test('una cantidad vacia no deja un numero fantasma', () {
      expect(etiquetaDeDosis('', 'mg'), 'mg');
      expect(etiquetaDeDosis('   ', 'mg'), 'mg');
    });
  });

  group('sinPrefijoDeForma', () {
    test('saca el prefijo y deja la instruccion real', () {
      expect(sinPrefijoDeForma('Forma: jarabe. Tomar con agua'),
          'Tomar con agua');
    });

    test('saca los prefijos acumulados de varias ediciones', () {
      // Cada guardado agregaba uno nuevo delante del anterior.
      expect(
        sinPrefijoDeForma(
            'Forma: comprimido. Forma: jarabe. Tomar con agua'),
        'Tomar con agua',
      );
    });

    test('un prefijo solo deja el campo vacio, no un resto', () {
      expect(sinPrefijoDeForma('Forma: jarabe'), isNull);
      expect(sinPrefijoDeForma('Forma: jarabe.'), isNull);
    });

    test('no toca una instruccion que nunca tuvo prefijo', () {
      expect(sinPrefijoDeForma('Tomar con las comidas.'),
          'Tomar con las comidas.');
    });

    test('no se come un texto que solo menciona la palabra', () {
      expect(sinPrefijoDeForma('Preguntar por la forma: comprimido o jarabe'),
          'Preguntar por la forma: comprimido o jarabe');
    });

    test('nulo y vacio quedan en nulo', () {
      expect(sinPrefijoDeForma(null), isNull);
      expect(sinPrefijoDeForma('   '), isNull);
    });
  });

  group('unidadesDeDosis', () {
    test('son exactamente las diez que acepta el backend', () {
      // ck_medications_dose_unit en 301_medications.sql. Si esta prueba falla
      // es porque alguien agrego una unidad en un lado y no en el otro, y el
      // guardado va a fallar con un error de restriccion.
      expect(
        unidadesDeDosis.toSet(),
        {'mg', 'g', 'ml', 'mcg', 'UI', 'gotas', 'comprimido', 'cápsula',
         'puff', 'parche'},
      );
    });

    test('cada unidad que se cuenta esta declarada con su forma leida', () {
      // Una unidad que se agregue a unidadesDeCantidad y no a la tabla de
      // plurales cae en el caso general y sale "2 comprimido". Esta tabla es
      // la lista completa de lo que debe leerse, una por cada unidad.
      const esperado = {
        'comprimido': ['1 comprimido', '2 comprimidos'],
        'cápsula': ['1 cápsula', '2 cápsulas'],
        'gotas': ['1 gota', '2 gotas'],
        'puff': ['1 puff', '2 puff'],
        'parche': ['1 parche', '2 parches'],
      };
      expect(esperado.keys.toSet(), unidadesDeCantidad.toSet(),
          reason: 'falta declarar como se lee una unidad que se cuenta');
      esperado.forEach((unidad, formas) {
        expect(etiquetaDeDosis('1', unidad), formas.first);
        expect(etiquetaDeDosis('2', unidad), formas.last);
      });
    });
  });
}

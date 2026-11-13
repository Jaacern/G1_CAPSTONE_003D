// Los idiomas de la cuidadora llegan de la API como codigos de dos letras.
import 'package:agecare_app/core/config/idiomas.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('los codigos conocidos se muestran en espanol', () {
    expect(nombreIdioma('es'), 'Español');
    expect(nombreIdioma('en'), 'Inglés');
    expect(nombreIdioma('qu'), 'Quechua');
  });

  test('no importa si el codigo viene en mayusculas', () {
    expect(nombreIdioma('PT'), 'Portugués');
  });

  test('un valor desconocido se muestra tal cual, sin perderlo', () {
    expect(nombreIdioma('mapudungun'), 'mapudungun');
    expect(nombreIdioma('ko'), 'ko');
  });
}

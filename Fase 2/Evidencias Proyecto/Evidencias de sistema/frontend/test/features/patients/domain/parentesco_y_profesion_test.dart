// Los codigos de parentesco y de profesion que manda la API, en palabras.
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el parentesco se muestra en espanol y con tilde', () {
    expect(relationshipLabel('conyuge'), 'Cónyuge');
    expect(relationshipLabel('nieta'), 'Nieta');
  });

  test('la profesion se muestra completa', () {
    expect(professionLabel('medico_general'), 'Médico general');
    expect(professionLabel('terapeuta_ocupacional'), 'Terapeuta ocupacional');
  });

  test('un codigo nuevo se muestra tal cual, sin perderse', () {
    expect(relationshipLabel('padrino'), 'padrino');
    expect(professionLabel('matrona'), 'matrona');
  });
}

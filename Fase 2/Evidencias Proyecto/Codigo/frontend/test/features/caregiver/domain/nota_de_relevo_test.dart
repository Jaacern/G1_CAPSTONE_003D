// La nota de relevo que deja la cuidadora al terminar el turno.
import 'package:agecare_app/features/caregiver/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('se lee de la API en la hora del telefono', () {
    final nota = HandoverNote.fromJson(const {
      'id': 'h-1',
      'text': 'Durmio mal, no quiso almorzar.',
      'author_name': 'Carla Rivas',
      'created_at': '2026-11-12T11:00:00Z',
    });

    expect(nota.id, 'h-1');
    expect(nota.authorName, 'Carla Rivas');
    expect(nota.createdAt.isUtc, isFalse);
  });

  test('acepta el id con el nombre antiguo note_id', () {
    final nota = HandoverNote.fromJson(const {
      'note_id': 'h-2',
      'text': 'Todo tranquilo.',
      'created_at': '2026-11-12T11:00:00Z',
    });

    expect(nota.id, 'h-2');
    expect(nota.authorName, '');
  });
}

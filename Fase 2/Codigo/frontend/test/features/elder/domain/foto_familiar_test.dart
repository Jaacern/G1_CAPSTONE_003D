// Las fotos que la familia comparte con el adulto mayor.
import 'package:agecare_app/features/elder/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('se lee de la API con sus reacciones', () {
    final foto = FamilyPhoto.fromJson(const {
      'id': 'f-1',
      'file_url': '/files/f-1',
      'caption': 'Tus nietos en la playa',
      'from_name': 'Daniela',
      'created_at': '2026-11-10T15:00:00Z',
      'reactions': {'love': 3, 'smile': 1},
    });

    expect(foto.url, '/files/f-1');
    expect(foto.caption, 'Tus nietos en la playa');
    expect(foto.fromName, 'Daniela');
    expect(foto.reactionCount('love'), 3);
    expect(foto.reactionCount('like'), 0);
  });

  test('sin remitente dice que es de la familia', () {
    final foto = FamilyPhoto.fromJson(const {
      'id': 'f-2',
      'url': '/files/f-2',
      'created_at': '2026-11-10T15:00:00Z',
    });

    expect(foto.fromName, 'Tu familia');
    expect(foto.reactions, isNull);
    expect(foto.reactionCount('love'), 0);
  });

  test('copyWith cambia solo las reacciones', () {
    final foto = FamilyPhoto(
      id: 'f-3',
      url: '/files/f-3',
      fromName: 'Pedro',
      createdAt: DateTime(2026, 11, 1),
      reactions: const {'love': 1},
    );

    final otra = foto.copyWith(reactions: const {'love': 2});

    expect(otra.reactionCount('love'), 2);
    expect(otra.id, 'f-3');
    expect(otra.fromName, 'Pedro');
    expect(foto.reactionCount('love'), 1); // la original no cambia
  });
}

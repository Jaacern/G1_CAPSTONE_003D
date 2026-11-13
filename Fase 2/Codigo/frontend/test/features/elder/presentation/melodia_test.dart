// La melodia que llega de GET /patients/{id}/music.
import 'package:agecare_app/features/elder/presentation/elder_melodies_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('se lee de la respuesta de la API', () {
    final m = Melodia.fromJson(const {
      'id': 7,
      'title': 'Melodía del 12 de noviembre, 19:30',
      'duration_seconds': 65,
      'audio_url': '/files/abc',
      'created_at': '2026-11-12T22:30:00Z',
    });

    expect(m.id, '7');
    expect(m.title, 'Melodía del 12 de noviembre, 19:30');
    expect(m.audioUrl, '/files/abc');
    expect(m.createdAt.isUtc, isFalse); // se muestra en la hora local
  });

  test('sin titulo se llama "Melodía"', () {
    final m = Melodia.fromJson(const {
      'id': 'm-1',
      'duration_seconds': 3,
      'created_at': '2026-11-12T22:30:00Z',
    });

    expect(m.title, 'Melodía');
  });

  test('la duracion se lee como minutos y segundos', () {
    Melodia conSegundos(int s) => Melodia(
          id: 'x',
          title: 'x',
          durationSeconds: s,
          audioUrl: '',
          createdAt: DateTime(2026),
        );

    expect(conSegundos(5).duracion, '0:05');
    expect(conSegundos(65).duracion, '1:05');
    expect(conSegundos(180).duracion, '3:00');
  });
}

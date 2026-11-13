// El enlace para escuchar una melodia sin cuenta (RF-67).
import 'package:agecare_app/features/elder/presentation/elder_melodies_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const respuesta = {
    'share_id': 's-1',
    'token': 'abc',
    'url': '/api/v1/music/shared/abc',
    'expires_at': '2026-11-15T22:00:00+00:00',
    'play_count': 0,
  };

  test('arma el enlace completo con la direccion del servidor', () {
    final e = EnlaceDeEscucha.fromJson(respuesta,
        servidor: 'https://api-dev.agecare.app');

    expect(e.shareId, 's-1');
    expect(e.url, 'https://api-dev.agecare.app/api/v1/music/shared/abc');
    expect(e.expiresAt.isUtc, isFalse); // se muestra en la hora local
  });

  test('no duplica la barra si el servidor termina en "/"', () {
    final e = EnlaceDeEscucha.fromJson(respuesta,
        servidor: 'http://localhost:8000/');

    expect(e.url, 'http://localhost:8000/api/v1/music/shared/abc');
  });

  test('si la API ya manda el enlace completo, se usa tal cual', () {
    final e = EnlaceDeEscucha.fromJson(
      {...respuesta, 'url': 'https://agecare.app/m/abc'},
      servidor: 'http://localhost:8000',
    );

    expect(e.url, 'https://agecare.app/m/abc');
  });
}

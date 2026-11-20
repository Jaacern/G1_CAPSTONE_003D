// ToneService.mezclar: arma un solo WAV con las notas que se tocaron en el
// Director Musical, para guardar la melodia sin pasar por el microfono.
import 'dart:typed_data';

import 'package:agecare_app/core/audio/tone_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lee un entero de 32 bits de la cabecera WAV (little endian).
int _u32(Uint8List wav, int offset) =>
    ByteData.sublistView(wav).getUint32(offset, Endian.little);

/// Las muestras de audio (16 bits con signo) que vienen despues de la
/// cabecera de 44 bytes.
List<int> _muestras(Uint8List wav) {
  final datos = ByteData.sublistView(wav, 44);
  return [
    for (var i = 0; i + 1 < datos.lengthInBytes; i += 2)
      datos.getInt16(i, Endian.little),
  ];
}

void main() {
  // No toca ninguna nota: los reproductores ni se llegan a crear.
  final tono = ToneService();

  test('sin notas devuelve un WAV vacio pero valido', () {
    final wav = tono.mezclar(const []);

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(wav.length, 44);
    expect(_u32(wav, 40), 0);
  });

  test('dura desde la primera nota hasta que termina la ultima', () {
    final wav = tono.mezclar(const [
      (offsetMs: 0, frequency: 440.0),
      (offsetMs: 1000, frequency: 523.25),
    ], durationMs: 500);

    // La ultima empieza al segundo y dura medio: 1,5 s a 44.100 muestras
    // por segundo, 2 bytes cada una.
    const bytes = 66150 * 2;
    expect(_u32(wav, 40), bytes);
    expect(wav.length, 44 + bytes);
  });

  test('notas superpuestas no saturan el audio', () {
    // Dos notas iguales al mismo tiempo suman el doble: hay que bajar el
    // volumen del total para que no se recorte.
    final wav = tono.mezclar(const [
      (offsetMs: 0, frequency: 440.0),
      (offsetMs: 0, frequency: 440.0),
    ], durationMs: 300);

    final pico =
        _muestras(wav).map((m) => m.abs()).reduce((a, b) => a > b ? a : b);
    expect(pico, lessThanOrEqualTo(29491)); // 90 % del maximo, sin recorte
    expect(pico, greaterThan(20000)); // se escucha, no quedo en silencio
  });
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sintetiza y reproduce tonos simples en memoria, sin necesidad de archivos
/// de audio (assets). Genera un WAV PCM 16-bit mono al vuelo y lo reproduce
/// con `audioplayers` vía [BytesSource], lo que funciona tanto en móvil como
/// en web.
///
/// Se usa en el "Director musical" de la vista del adulto mayor: botones
/// grandes y coloridos que suenan al pulsarlos. El objetivo es lúdico y
/// estimulante, no musical de precisión.
class ToneService {
  ToneService();

  /// Un reproductor por voz permite que varias notas suenen encabalgadas
  /// (si el adulto mayor toca rápido) sin cortarse entre sí. Se rota en
  /// round-robin sobre un pequeño grupo.
  final List<AudioPlayer> _pool =
      List.generate(6, (_) => AudioPlayer()..setReleaseMode(ReleaseMode.stop));
  int _next = 0;

  static const int _sampleRate = 44100;

  /// Reproduce un tono de [frequency] Hz durante [durationMs] milisegundos.
  /// La onda lleva un envolvente suave (fade in/out) para evitar los clics
  /// molestos del inicio y fin abruptos.
  Future<void> play(double frequency,
      {int durationMs = 600, double volume = 0.9}) async {
    final bytes = _buildWav(frequency, durationMs);
    final player = _pool[_next];
    _next = (_next + 1) % _pool.length;
    try {
      await player.stop();
      await player.setVolume(volume);
      await player.play(BytesSource(bytes, mimeType: 'audio/wav'));
    } catch (_) {
      // Si una plataforma no soporta BytesSource, fallamos en silencio: el
      // botón sigue dando retroalimentación visual.
    }
  }

  /// Genera un WAV PCM 16-bit mono con un tono senoidal + armónico suave para
  /// que suene más cálido (menos "pitido" puro) y con envolvente ADSR simple.
  Uint8List _buildWav(double freq, int durationMs) {
    final totalSamples = (_sampleRate * durationMs / 1000).round();
    final data = Int16List(totalSamples);

    final attack = (_sampleRate * 0.02).round(); // 20 ms de entrada
    final release = (_sampleRate * 0.12).round(); // 120 ms de salida
    const twoPi = 2 * math.pi;

    for (var i = 0; i < totalSamples; i++) {
      final t = i / _sampleRate;
      // Fundamental + un armónico tenue para calidez.
      var sample = math.sin(twoPi * freq * t) +
          0.18 * math.sin(twoPi * freq * 2 * t);
      sample /= 1.18;

      // Envolvente (fade in/out) para evitar clics.
      double env = 1.0;
      if (i < attack) {
        env = i / attack;
      } else if (i > totalSamples - release) {
        env = (totalSamples - i) / release;
      }

      data[i] = (sample * env * 32767 * 0.9).round().clamp(-32768, 32767);
    }

    return _wrapWav(data);
  }

  /// Envuelve las muestras PCM en una cabecera WAV (RIFF) estándar.
  Uint8List _wrapWav(Int16List samples) {
    const channels = 1;
    const bitsPerSample = 16;
    const byteRate = _sampleRate * channels * bitsPerSample ~/ 8;
    const blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = samples.length * 2;
    final fileSize = 44 + dataSize;

    final bytes = BytesBuilder();
    void writeString(String s) => bytes.add(s.codeUnits);
    void writeUint32(int v) => bytes.add([
          v & 0xff,
          (v >> 8) & 0xff,
          (v >> 16) & 0xff,
          (v >> 24) & 0xff,
        ]);
    void writeUint16(int v) => bytes.add([v & 0xff, (v >> 8) & 0xff]);

    writeString('RIFF');
    writeUint32(fileSize - 8);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16); // tamaño del sub-chunk fmt
    writeUint16(1); // PCM
    writeUint16(channels);
    writeUint32(_sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(bitsPerSample);
    writeString('data');
    writeUint32(dataSize);
    bytes.add(samples.buffer.asUint8List(0, dataSize));

    return bytes.toBytes();
  }

  Future<void> dispose() async {
    for (final p in _pool) {
      await p.dispose();
    }
  }
}

final toneServiceProvider = Provider<ToneService>((ref) {
  final s = ToneService();
  ref.onDispose(s.dispose);
  return s;
});

import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Formatos de grabación, en orden de preferencia.
///
/// El formato no se puede fijar de antemano. En el teléfono se graba AAC sin
/// problema, pero en el navegador cada uno graba solo lo que soporta su
/// MediaRecorder, y la lista de tipos que el servidor acepta
/// (ALLOWED_CONTENT_TYPES) es corta. Así que se le pregunta al grabador cuál
/// de estos puede entregar y se usa el primero que sirva. Los dos están en la
/// lista del servidor, de ahí que no aparezca opus, que es lo que ofrecen
/// varios navegadores pero el servidor todavía no acepta.
const _preferidos = <AudioEncoder, ({String extension, String mime})>{
  AudioEncoder.aacLc: (extension: 'm4a', mime: 'audio/aac'),
  AudioEncoder.wav: (extension: 'wav', mime: 'audio/wav'),
};

/// La plataforma no puede grabar en ninguno de los formatos que el servidor
/// acepta. Pasa en algunos navegadores; en el teléfono no ocurre.
class SinFormatoSoportado implements Exception {
  const SinFormatoSoportado();

  static const mensaje = 'Este navegador no puede grabar audio en un formato '
      'que el servidor acepte. Prueba desde la aplicación del teléfono.';

  @override
  String toString() => mensaje;
}

typedef FormatoGrabacion = ({
  AudioEncoder encoder,
  String extension,
  String mime,
});

/// El primer formato de [_preferidos] que esta plataforma soporte.
Future<FormatoGrabacion> formatoDeGrabacion(AudioRecorder grabadora) async {
  for (final p in _preferidos.entries) {
    if (await grabadora.isEncoderSupported(p.key)) {
      return (
        encoder: p.key,
        extension: p.value.extension,
        mime: p.value.mime,
      );
    }
  }
  throw const SinFormatoSoportado();
}

/// Ruta donde escribir la grabación.
///
/// En el navegador no hay sistema de archivos ni directorio temporal, y
/// path_provider no existe ahí. El grabador devuelve un blob y la ruta que se
/// le pasa se ignora, así que va vacía.
Future<String> rutaDeGrabacion(String nombre, String extension) async {
  if (kIsWeb) return '';
  final dir = await getTemporaryDirectory();
  final marca = DateTime.now().millisecondsSinceEpoch;
  return '${dir.path}/${nombre}_$marca.$extension';
}

/// Borra el temporal de una grabación que ya se subió o que se descartó.
///
/// En el navegador no hay nada que borrar, el blob lo libera el navegador
/// solo. Nunca levanta, porque dejar un temporal no es motivo para que se
/// caiga la pantalla.
Future<void> borrarGrabacion(String path) async {
  if (kIsWeb || path.isEmpty) return;
  try {
    await File(path).delete();
  } catch (_) {}
}

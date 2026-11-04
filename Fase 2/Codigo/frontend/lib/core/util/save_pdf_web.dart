import 'dart:convert';
import 'dart:typed_data';
// dart:html sigue siendo la vía estándar para disparar una descarga en Flutter
// web. package:web/dart:js_interop es el reemplazo moderno pero exige más
// andamiaje; para el alcance del capstone se mantiene dart:html.
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// Web: abre el PDF en una pestaña nueva (el navegador ofrece ver/descargar).
/// Se usa un data URL en base64 para no depender de Blob URLs que a veces el
/// navegador bloquea al abrir en pestaña.
Future<bool> savePdfImpl(Uint8List bytes, String filename) async {
  final b64 = base64Encode(bytes);
  final url = 'data:application/pdf;base64,$b64';
  // Ancla con download: muestra/descarga el PDF con el nombre sugerido.
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..target = '_blank';
  anchor.click();
  return true;
}

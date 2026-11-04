import 'dart:typed_data';

// Selector de implementación por plataforma: en web se dispara la descarga del
// navegador; en móvil/escritorio se guarda a un temporal y se abre/comparte.
// La compilación condicional evita importar dart:html en móvil y dart:io en web.
import 'save_pdf_stub.dart'
    if (dart.library.html) 'save_pdf_web.dart'
    if (dart.library.io) 'save_pdf_io.dart';

/// Abre o comparte un PDF ya descargado (bytes). [filename] es el nombre
/// sugerido del archivo. Devuelve true si se pudo entregar al usuario.
Future<bool> savePdf(Uint8List bytes, String filename) =>
    savePdfImpl(bytes, filename);

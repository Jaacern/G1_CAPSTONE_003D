import 'dart:typed_data';

/// Implementación por defecto (no debería ejecutarse: siempre gana web o io).
Future<bool> savePdfImpl(Uint8List bytes, String filename) async => false;

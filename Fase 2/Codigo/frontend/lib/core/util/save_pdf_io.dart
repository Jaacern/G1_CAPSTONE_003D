import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Móvil / escritorio: guarda el PDF en un temporal y abre la hoja de compartir
/// (enviar por WhatsApp/correo, guardar, imprimir). Así el familiar puede pasar
/// la hoja de emergencia al paramédico desde su teléfono.
Future<bool> savePdfImpl(Uint8List bytes, String filename) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles(
    [XFile(file.path, mimeType: 'application/pdf', name: filename)],
    subject: 'Hoja de emergencia',
  );
  return true;
}

import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Resultado de una subida: URL pública/servida del archivo ya almacenado.
class UploadedFile {
  const UploadedFile({required this.fileUrl, required this.uploadId});
  final String fileUrl;
  final String uploadId;

  /// Id del archivo, sacado de [fileUrl].
  ///
  /// Casi todos los endpoints reciben el `media_url` entero y resuelven el id
  /// en el servidor. El de música lo pide suelto (`file_id`), así que hay que
  /// sacarlo de la URL, que es la única forma en que el front lo conoce. Vive
  /// aquí y no en cada pantalla para que haya un solo lugar donde arreglarlo
  /// si la forma de la URL cambia.
  String? get fileId => _uuid.firstMatch(fileUrl)?.group(0);

  static final RegExp _uuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  );
}

/// Servicio de subida de binarios (fotos, audios, documentos, recetas).
///
/// Patrón de la Especificación de Endpoints v1 (sección uploads):
///   1. POST /uploads  -> { upload_id, upload_url (SAS, exp. 15 min), file_url }
///   2. PUT <upload_url> con el binario (a Azure Blob directamente).
///   3. Se usa file_url en el recurso destino (foto, documento, mensaje...).
///
/// Para leer un archivo después hay que pedir un enlace firmado con
/// [signedUrl]: el file_url guardado apunta a la API y necesita credencial,
/// y los widgets de imagen no mandan cabeceras.
class UploadService {
  /// [raw] solo existe para reemplazar el cliente HTTP real por uno falso en
  /// los tests (ver test/core/network/subida_de_archivos_test.dart). En la
  /// app nunca se pasa: el PUT del binario va directo al almacenamiento, sin
  /// los interceptores ni la URL base de [ApiClient].
  UploadService(this._api, {@visibleForTesting Dio? raw})
      : _raw = raw ?? Dio();
  final ApiClient _api;
  final Dio _raw;

  /// Sube un archivo elegido por el usuario (selector de fotos, grabadora).
  ///
  /// Recibe un XFile y no un File de dart:io porque en el navegador lo que
  /// entrega el selector no es un archivo del disco sino un blob, y la ruta
  /// que trae no se puede abrir. XFile.readAsBytes funciona en las dos
  /// plataformas, que es lo unico que necesita la subida.
  Future<UploadedFile> uploadFile(
    XFile file, {
    required String kind, // 'photo' | 'document' | 'audio' | 'prescription' | 'avatar' | 'catalog' | 'certification'
    String? patientId,
    String? contentType,
  }) async {
    final bytes = await file.readAsBytes();
    return uploadBytes(bytes,
        filename: file.name,
        kind: kind,
        patientId: patientId,
        contentType: contentType ?? _tipoDe(file));
  }

  Future<UploadedFile> uploadBytes(
    Uint8List bytes, {
    required String filename,
    required String kind,
    String? patientId,
    String? contentType,
  }) async {
    final ct = contentType ?? _guessContentType(filename);
    final res = await _api.post<Map<String, dynamic>>('/uploads', data: {
      'filename': filename,
      'content_type': ct,
      'kind': kind,
      'size': bytes.length,
      // Obligatorio para los kind del expediente (photo, document, audio,
      // prescription). El backend lo ignora en los demás ámbitos.
      if (patientId != null) 'patient_id': patientId,
    });

    final uploadUrl = res['upload_url'] as String;
    await _raw.put(
      uploadUrl,
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          // El navegador no deja fijar Content-Length a mano: lo pone solo y
          // rechaza el intento con un aviso en la consola. En telefono si hay
          // que declararlo, porque el cuerpo va como flujo.
          if (!kIsWeb) Headers.contentLengthHeader: bytes.length,
          'Content-Type': ct,
          'x-ms-blob-type': 'BlockBlob', // Azure Blob
        },
      ),
    );

    return UploadedFile(
      fileUrl: res['file_url'] as String,
      uploadId: (res['upload_id'] ?? '') as String,
    );
  }

  /// Pide un enlace de lectura de vida corta para un archivo ya subido.
  ///
  /// Recibe el file_url que quedó guardado en el recurso (o el id suelto) y
  /// devuelve una URL que se puede abrir sin cabeceras, lista para
  /// Image.network o para el reproductor de audio. Vence en 5 minutos, así
  /// que se pide al momento de mostrar, no se guarda.
  Future<String> signedUrl(String fileUrlOrId) async {
    final id = fileIdOf(fileUrlOrId);
    if (id == null) return fileUrlOrId; // URL externa o de ejemplo, se usa tal cual
    final res = await _api.get<Map<String, dynamic>>('/files/$id/download');
    return res['url'] as String;
  }

  /// Saca el id de archivo de un file_url de la API.
  ///
  /// Devuelve null si la URL no es nuestra, que es el caso de los datos de
  /// ejemplo de los repositorios y de cualquier imagen externa.
  static String? fileIdOf(String value) {
    final limpio = value.split('?').first;
    if (!limpio.contains('/files/')) {
      return _esUuid(limpio) ? limpio : null;
    }
    final ultimo = limpio.split('/').where((p) => p.isNotEmpty).last;
    return _esUuid(ultimo) ? ultimo : null;
  }

  static bool _esUuid(String s) => RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(s);

  /// Tipo del archivo elegido.
  ///
  /// Se prefiere la extension porque el servidor solo acepta una lista corta
  /// de tipos y la extension es la que decide cual es. El mimeType que
  /// informa el navegador queda como respaldo, para cuando el nombre no trae
  /// una extension reconocible.
  String _tipoDe(XFile file) {
    final porNombre = _guessContentType(file.name);
    if (porNombre != 'application/octet-stream') return porNombre;
    return file.mimeType ?? porNombre;
  }

  String _guessContentType(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'pdf':
        return 'application/pdf';
      case 'm4a':
      case 'aac':
        return 'audio/aac';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      default:
        return 'application/octet-stream';
    }
  }
}

final uploadServiceProvider = Provider<UploadService>(
    (ref) => UploadService(ref.watch(apiClientProvider)));

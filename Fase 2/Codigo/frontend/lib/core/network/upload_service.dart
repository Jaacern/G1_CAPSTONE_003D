import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Resultado de una subida: URL pública/servida del archivo ya almacenado.
class UploadedFile {
  const UploadedFile({required this.fileUrl, required this.uploadId});
  final String fileUrl;
  final String uploadId;
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
  UploadService(this._api);
  final ApiClient _api;
  final Dio _raw = Dio();

  Future<UploadedFile> uploadFile(
    File file, {
    required String kind, // 'photo' | 'document' | 'audio' | 'prescription' | 'avatar' | 'catalog' | 'certification'
    String? patientId,
    String? contentType,
  }) async {
    final bytes = await file.readAsBytes();
    final name = file.path.split(Platform.pathSeparator).last;
    return uploadBytes(bytes,
        filename: name,
        kind: kind,
        patientId: patientId,
        contentType: contentType);
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
          Headers.contentLengthHeader: bytes.length,
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

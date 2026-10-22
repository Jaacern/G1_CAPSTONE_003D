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
class UploadService {
  UploadService(this._api);
  final ApiClient _api;
  final Dio _raw = Dio();

  Future<UploadedFile> uploadFile(
    File file, {
    required String kind, // 'photo' | 'document' | 'audio' | 'prescription'
    String? contentType,
  }) async {
    final bytes = await file.readAsBytes();
    final name = file.path.split(Platform.pathSeparator).last;
    return uploadBytes(bytes,
        filename: name, kind: kind, contentType: contentType);
  }

  Future<UploadedFile> uploadBytes(
    Uint8List bytes, {
    required String filename,
    required String kind,
    String? contentType,
  }) async {
    final ct = contentType ?? _guessContentType(filename);
    final res = await _api.post<Map<String, dynamic>>('/uploads', data: {
      'filename': filename,
      'content_type': ct,
      'kind': kind,
      'size': bytes.length,
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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

abstract class DocumentsRepository {
  Future<List<PatientDocument>> listDocuments(String patientId);
  Future<PatientDocument> addDocument(
    String patientId, {
    required String fileUrl,
    required String title,
    required String category,
  });
  Future<void> deleteDocument(String documentId);
  Future<String> downloadUrl(String documentId);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class DocumentsRepositoryHttp implements DocumentsRepository {
  DocumentsRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<PatientDocument>> listDocuments(String patientId) async {
    final data = await _api
        .get<Map<String, dynamic>>('/patients/$patientId/documents');
    return ((data['items'] ?? []) as List)
        .map((e) => PatientDocument.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<PatientDocument> addDocument(
    String patientId, {
    required String fileUrl,
    required String title,
    required String category,
  }) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/documents',
      data: {'file_url': fileUrl, 'title': title, 'category': category},
    );
    return PatientDocument.fromJson(res);
  }

  @override
  Future<void> deleteDocument(String documentId) =>
      _api.delete<void>('/documents/$documentId');

  @override
  Future<String> downloadUrl(String documentId) async {
    final res = await _api
        .get<Map<String, dynamic>>('/documents/$documentId/download');
    return res['url'] as String;
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class DocumentsRepositoryMock implements DocumentsRepository {
  DocumentsRepositoryMock() {
    _seed();
  }

  final List<PatientDocument> _docs = [];

  void _seed() {
    final now = DateTime.now();
    _docs.addAll([
      PatientDocument(
        id: 'doc-1',
        title: 'Receta cardiología',
        category: 'receta',
        fileUrl: 'https://example.com/docs/receta-cardiologia.pdf',
        createdAt: now.subtract(const Duration(days: 3)),
        uploaderName: 'Dra. Pérez',
      ),
      PatientDocument(
        id: 'doc-2',
        title: 'Estudio de laboratorio (biometría)',
        category: 'estudio',
        fileUrl: 'https://example.com/docs/laboratorio.pdf',
        createdAt: now.subtract(const Duration(days: 10)),
        uploaderName: 'Laboratorio Central',
      ),
      PatientDocument(
        id: 'doc-3',
        title: 'Credencial INE',
        category: 'identificacion',
        fileUrl: 'https://example.com/docs/credencial.jpg',
        createdAt: now.subtract(const Duration(days: 60)),
        uploaderName: 'Familia',
      ),
    ]);
  }

  @override
  Future<List<PatientDocument>> listDocuments(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final list = List.of(_docs)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<PatientDocument> addDocument(
    String patientId, {
    required String fileUrl,
    required String title,
    required String category,
  }) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final doc = PatientDocument(
      id: 'doc-${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      category: category,
      fileUrl: fileUrl,
      createdAt: DateTime.now(),
      uploaderName: 'Tú',
    );
    _docs.add(doc);
    return doc;
  }

  @override
  Future<void> deleteDocument(String documentId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    _docs.removeWhere((d) => d.id == documentId);
  }

  @override
  Future<String> downloadUrl(String documentId) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final doc = _docs.firstWhere(
      (d) => d.id == documentId,
      orElse: () => throw ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'El documento solicitado no existe.',
      ),
    );
    return doc.fileUrl;
  }
}

final documentsRepositoryProvider = Provider<DocumentsRepository>((ref) {
  if (AppConfig.useMocks) return DocumentsRepositoryMock();
  return DocumentsRepositoryHttp(ref.watch(apiClientProvider));
});

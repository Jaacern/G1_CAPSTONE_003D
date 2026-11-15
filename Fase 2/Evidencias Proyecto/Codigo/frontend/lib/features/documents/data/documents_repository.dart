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
    PatientDocument doc(String id, String titulo, String cat, String archivo,
            int dias, String autor) =>
        PatientDocument(
          id: id,
          title: titulo,
          category: cat,
          fileUrl: 'https://example.com/docs/$archivo',
          createdAt: now.subtract(Duration(days: dias)),
          uploaderName: autor,
        );
    _docs.addAll([
      doc('doc-1', 'Receta cardiología (losartán)', 'receta',
          'receta-cardiologia.pdf', 3, 'Dra. Carolina Soto'),
      doc('doc-2', 'Receta metformina', 'receta', 'receta-metformina.pdf', 40,
          'Dra. Carolina Soto'),
      doc('doc-3', 'Hemograma y perfil bioquímico', 'estudio',
          'hemograma.pdf', 10, 'Daniela Fuentes'),
      doc('doc-4', 'Hemoglobina glicosilada', 'estudio', 'hba1c.pdf', 95,
          'Daniela Fuentes'),
      doc('doc-5', 'Radiografía de tórax', 'imagen', 'rx-torax.jpg', 22,
          'Marisol Tapia'),
      doc('doc-6', 'Informe de cardiología', 'informe',
          'informe-cardiologia.pdf', 30, 'Dra. Carolina Soto'),
      doc('doc-7', 'Epicrisis hospitalización enero', 'epicrisis',
          'epicrisis.pdf', 280, 'Daniela Fuentes'),
      doc('doc-8', 'Credencial Fonasa', 'prevision', 'fonasa.jpg', 120,
          'Daniela Fuentes'),
      doc('doc-9', 'Cédula de identidad', 'identificacion', 'cedula.jpg', 200,
          'Daniela Fuentes'),
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

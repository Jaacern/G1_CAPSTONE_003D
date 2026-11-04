import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../domain/treatment.dart';

/// Acceso a los endpoints de tratamientos (Hito 3).
class TreatmentsRepository {
  TreatmentsRepository(this._api);
  final ApiClient _api;

  /// Tratamiento vigente del paciente (con historial si [history] es true).
  Future<TreatmentBundle> getTreatments(String patientId,
      {bool history = false}) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/treatments',
      query: {if (history) 'include': 'history'},
    );
    return TreatmentBundle.fromJson(data);
  }

  /// Crea un tratamiento nuevo que reemplaza al vigente. Solo médico.
  Future<Treatment> createTreatment(
    String patientId, {
    required List<TreatmentItemDraft> items,
    String specialty = 'general',
    String? note,
    DateTime? reviewDate,
    bool confirmAllergy = false,
  }) async {
    final data = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/treatments',
      data: {
        'specialty': specialty,
        'items': items.map((e) => e.toJson()).toList(),
        if (confirmAllergy) 'confirm_allergy': true,
        if (note != null && note.trim().isNotEmpty) 'note': note,
        if (reviewDate != null)
          'review_date':
              '${reviewDate.year.toString().padLeft(4, '0')}-${reviewDate.month.toString().padLeft(2, '0')}-${reviewDate.day.toString().padLeft(2, '0')}',
      },
    );
    return Treatment.fromJson(data);
  }

  /// Adjunta una receta formal (documento médico) a un tratamiento.
  Future<void> attachDocument(
          String patientId, String treatmentId, String documentId) =>
      _api.post<void>(
        '/patients/$patientId/treatments/$treatmentId/documents',
        data: {'document_id': documentId},
      );

  /// Catálogo de fármacos para prescribir con unidad y rango seguros.
  Future<List<DrugCatalogItem>> drugCatalog() async {
    final data = await _api.get<List<dynamic>>('/drugs/catalog');
    return data
        .map((e) => DrugCatalogItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final treatmentsRepositoryProvider = Provider<TreatmentsRepository>(
  (ref) => TreatmentsRepository(ref.watch(apiClientProvider)),
);

/// Catálogo de fármacos (cacheado mientras viva el provider).
final drugCatalogProvider = FutureProvider<List<DrugCatalogItem>>((ref) {
  return ref.watch(treatmentsRepositoryProvider).drugCatalog();
});

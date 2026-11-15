import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
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

/// Versión en memoria para el modo de prueba (USE_MOCKS=true). Guarda un
/// tratamiento vigente por especialidad y, al crear uno nuevo, el anterior
/// de esa área pasa a histórico, igual que el servidor.
class TreatmentsRepositoryMock implements TreatmentsRepository {
  final Map<String, List<Treatment>> _porPaciente = {};

  // No usa red; solo satisface la interfaz de la clase real.
  @override
  ApiClient get _api => throw UnimplementedError('modo de prueba sin red');

  List<Treatment> _de(String patientId) =>
      _porPaciente.putIfAbsent(patientId, () => [
            Treatment(
              treatmentId: 'mock-t-$patientId',
              status: 'vigente',
              specialty: 'general',
              prescriberName: 'Dra. Carolina Soto',
              effectiveFrom: DateTime.now().subtract(const Duration(days: 30)),
              items: const [
                TreatmentItem(
                  itemId: 'mock-i-1',
                  name: 'Losartán 50 mg',
                  dose: '50 mg',
                  doseAmount: 50,
                  doseUnit: 'mg',
                  times: ['08:00', '20:00'],
                  daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
                  graceWindowMin: 60,
                  action: 'kept',
                  drugCode: 'losartan',
                ),
              ],
            ),
          ]);

  @override
  Future<TreatmentBundle> getTreatments(String patientId,
      {bool history = false}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final todos = _de(patientId);
    final areas = <String>{for (final t in todos) t.specialty};
    final grupos = [
      for (final a in areas)
        SpecialtyGroup(
          specialty: a,
          current: todos
              .where((t) => t.specialty == a && t.vigente)
              .firstOrNull,
          history: history
              ? todos.where((t) => t.specialty == a && !t.vigente).toList()
              : const [],
        ),
    ];
    return TreatmentBundle(
      current: todos.where((t) => t.vigente).firstOrNull,
      history: history ? todos.where((t) => !t.vigente).toList() : const [],
      bySpecialty: grupos,
    );
  }

  @override
  Future<Treatment> createTreatment(
    String patientId, {
    required List<TreatmentItemDraft> items,
    String specialty = 'general',
    String? note,
    DateTime? reviewDate,
    bool confirmAllergy = false,
  }) async {
    await Future.delayed(const Duration(milliseconds: 250));
    final lista = _de(patientId);
    for (var i = 0; i < lista.length; i++) {
      final t = lista[i];
      if (t.specialty == specialty && t.vigente) {
        lista[i] = Treatment(
          treatmentId: t.treatmentId,
          status: 'superseded',
          specialty: t.specialty,
          prescriberName: t.prescriberName,
          effectiveFrom: t.effectiveFrom,
          effectiveTo: DateTime.now(),
          items: t.items,
        );
      }
    }
    final nuevo = Treatment(
      treatmentId: 'mock-t-${DateTime.now().microsecondsSinceEpoch}',
      status: 'vigente',
      specialty: specialty,
      prescriberName: 'Dra. Carolina Soto',
      effectiveFrom: DateTime.now(),
      reviewDate: reviewDate,
      note: note,
      items: [
        for (final d in items.where((d) => !d.removed))
          TreatmentItem(
            itemId: 'mock-i-${d.name.hashCode}',
            name: d.name,
            dose: '${d.doseAmount} ${d.doseUnit}',
            doseAmount: d.doseAmount,
            doseUnit: d.doseUnit,
            times: d.times,
            daysOfWeek: const [1, 2, 3, 4, 5, 6, 7],
            graceWindowMin: 60,
            action: 'added',
            drugCode: d.drugCode,
            instructions: d.instructions,
          ),
      ],
    );
    lista.add(nuevo);
    return nuevo;
  }

  @override
  Future<void> attachDocument(
          String patientId, String treatmentId, String documentId) async {}

  @override
  Future<List<DrugCatalogItem>> drugCatalog() async => const [
        DrugCatalogItem(
            code: 'losartan',
            activeIngredient: 'Losartán',
            label: 'Losartán',
            form: 'comprimido',
            route: 'oral',
            unit: 'mg',
            doseMin: 12.5,
            doseMax: 100),
        DrugCatalogItem(
            code: 'metformina',
            activeIngredient: 'Metformina',
            label: 'Metformina',
            form: 'comprimido',
            route: 'oral',
            unit: 'mg',
            doseMin: 500,
            doseMax: 1000),
        DrugCatalogItem(
            code: 'paracetamol',
            activeIngredient: 'Paracetamol',
            label: 'Paracetamol',
            form: 'comprimido',
            route: 'oral',
            unit: 'mg',
            doseMin: 250,
            doseMax: 1000),
      ];
}

final treatmentsRepositoryProvider = Provider<TreatmentsRepository>((ref) {
  if (AppConfig.useMocks) return TreatmentsRepositoryMock();
  return TreatmentsRepository(ref.watch(apiClientProvider));
});

/// Catálogo de fármacos (cacheado mientras viva el provider).
final drugCatalogProvider = FutureProvider<List<DrugCatalogItem>>((ref) {
  return ref.watch(treatmentsRepositoryProvider).drugCatalog();
});

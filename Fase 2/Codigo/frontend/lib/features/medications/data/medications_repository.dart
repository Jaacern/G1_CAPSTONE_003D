import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

abstract class MedicationsRepository {
  Future<List<Medication>> listMedications(String patientId);
  Future<Medication> createMedication(String patientId, NewMedication data);
  Future<Medication> updateMedication(
      String patientId, String medicationId, NewMedication data);
  Future<void> deleteMedication(String patientId, String medicationId);
  Future<List<Dose>> listDoses(String patientId, {DateTime? date});
  Future<Dose> logDose(String doseId, DoseStatus status, {String? note});
  Future<Adherence> adherence(String patientId,
      {DateTime? from, DateTime? to});
  Future<PrescriptionDraft> scanPrescription(String patientId, String fileUrl);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class MedicationsRepositoryHttp implements MedicationsRepository {
  MedicationsRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<Medication>> listMedications(String patientId) async {
    final data =
        await _api.get<Map<String, dynamic>>('/patients/$patientId/medications');
    return ((data['items'] ?? []) as List)
        .map((e) => Medication.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Medication> createMedication(
      String patientId, NewMedication data) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/medications',
      data: data.toJson(),
    );
    return Medication.fromJson(res);
  }

  @override
  Future<Medication> updateMedication(
      String patientId, String medicationId, NewMedication data) async {
    final res = await _api.patch<Map<String, dynamic>>(
      '/patients/$patientId/medications/$medicationId',
      data: data.toJson(),
    );
    return Medication.fromJson(res);
  }

  @override
  Future<void> deleteMedication(String patientId, String medicationId) =>
      _api.delete<void>('/patients/$patientId/medications/$medicationId');

  @override
  Future<List<Dose>> listDoses(String patientId, {DateTime? date}) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/doses',
      query: {
        if (date != null) 'date': _dateOnly(date),
      },
    );
    return ((data['items'] ?? []) as List)
        .map((e) => Dose.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Dose> logDose(String doseId, DoseStatus status, {String? note}) async {
    // Backend (6.6): status + (si taken) administered_at + (si missed) reason.
    // El backend exige 'reason' cuando status='missed'.
    final res = await _api.post<Map<String, dynamic>>(
      '/doses/$doseId/log',
      data: {
        'status': status.apiValue,
        if (status == DoseStatus.taken)
          'administered_at': DateTime.now().toIso8601String(),
        if (note != null && note.isNotEmpty) 'reason': note,
      },
    );
    return Dose.fromJson(res);
  }

  @override
  Future<Adherence> adherence(String patientId,
      {DateTime? from, DateTime? to}) async {
    // Backend (6.7): date_from y date_to son REQUERIDOS. Si no se pasan,
    // usamos los últimos 7 días como rango por defecto.
    final now = DateTime.now();
    final effectiveTo = to ?? now;
    final effectiveFrom = from ?? now.subtract(const Duration(days: 7));
    final data = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/adherence',
      query: {
        'date_from': _dateOnly(effectiveFrom),
        'date_to': _dateOnly(effectiveTo),
      },
    );
    return Adherence.fromJson(data);
  }

  @override
  Future<PrescriptionDraft> scanPrescription(
      String patientId, String fileUrl) async {
    // El backend aún no tiene OCR de recetas. Evitamos llamar a un endpoint
    // inexistente y damos un mensaje claro de "Próximamente".
    throw ApiException(
      statusCode: 501,
      code: 'NOT_IMPLEMENTED',
      message: 'El escaneo de recetas (OCR) estará disponible próximamente.',
    );
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class MedicationsRepositoryMock implements MedicationsRepository {
  MedicationsRepositoryMock() {
    _seed();
  }

  final List<Medication> _meds = [];
  final List<Dose> _doses = [];

  DateTime _at(DateTime day, int h, int m) =>
      DateTime(day.year, day.month, day.day, h, m);

  void _seed() {
    final today = DateTime.now();
    final start = today.subtract(const Duration(days: 30));

    _meds.addAll([
      Medication(
        id: 'm-losartan',
        name: 'Losartán',
        dose: '50',
        unit: 'mg',
        form: 'comprimido',
        schedule: const ['08:00'],
        instructions: 'Tomar en ayunas.',
        startDate: start,
      ),
      Medication(
        id: 'm-metformina',
        name: 'Metformina',
        dose: '850',
        unit: 'mg',
        form: 'comprimido',
        schedule: const ['08:00', '20:00'],
        instructions: 'Tomar con las comidas.',
        startDate: start,
      ),
      Medication(
        id: 'm-atorvastatina',
        name: 'Atorvastatina',
        dose: '20',
        unit: 'mg',
        form: 'comprimido',
        schedule: const ['22:00'],
        instructions: 'Tomar por la noche.',
        startDate: start,
      ),
    ]);

    // Dosis de hoy: algunas ya tomadas (las de la mañana).
    _doses.addAll([
      Dose(
        id: 'd-1',
        medicationId: 'm-losartan',
        medicationName: 'Losartán',
        scheduledAt: _at(today, 8, 0),
        status: DoseStatus.taken,
        loggedAt: _at(today, 8, 5),
        dose: '50',
        unit: 'mg',
      ),
      Dose(
        id: 'd-2',
        medicationId: 'm-metformina',
        medicationName: 'Metformina',
        scheduledAt: _at(today, 8, 0),
        status: DoseStatus.taken,
        loggedAt: _at(today, 8, 10),
        dose: '850',
        unit: 'mg',
      ),
      Dose(
        id: 'd-3',
        medicationId: 'm-metformina',
        medicationName: 'Metformina',
        scheduledAt: _at(today, 20, 0),
        status: DoseStatus.pending,
        dose: '850',
        unit: 'mg',
      ),
      Dose(
        id: 'd-4',
        medicationId: 'm-atorvastatina',
        medicationName: 'Atorvastatina',
        scheduledAt: _at(today, 22, 0),
        status: DoseStatus.pending,
        dose: '20',
        unit: 'mg',
      ),
    ]);
  }

  @override
  Future<List<Medication>> listMedications(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return _meds.where((m) => m.active).toList();
  }

  @override
  Future<Medication> createMedication(
      String patientId, NewMedication data) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final med = Medication(
      id: 'm-${DateTime.now().millisecondsSinceEpoch}',
      name: data.name,
      dose: data.dose,
      unit: data.unit,
      form: data.form,
      schedule: data.schedule,
      instructions: data.instructions,
      startDate: data.startDate,
      endDate: data.endDate,
    );
    _meds.add(med);
    return med;
  }

  @override
  Future<Medication> updateMedication(
      String patientId, String medicationId, NewMedication data) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final i = _meds.indexWhere((m) => m.id == medicationId);
    final updated = Medication(
      id: medicationId,
      name: data.name,
      dose: data.dose,
      unit: data.unit,
      form: data.form,
      schedule: data.schedule,
      instructions: data.instructions,
      startDate: data.startDate,
      endDate: data.endDate,
    );
    if (i >= 0) {
      _meds[i] = updated;
    } else {
      _meds.add(updated);
    }
    return updated;
  }

  @override
  Future<void> deleteMedication(String patientId, String medicationId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    _meds.removeWhere((m) => m.id == medicationId);
  }

  @override
  Future<List<Dose>> listDoses(String patientId, {DateTime? date}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (date == null) return List.of(_doses);
    return _doses
        .where((d) =>
            d.scheduledAt.year == date.year &&
            d.scheduledAt.month == date.month &&
            d.scheduledAt.day == date.day)
        .toList();
  }

  @override
  Future<Dose> logDose(String doseId, DoseStatus status, {String? note}) async {
    await Future.delayed(const Duration(milliseconds: 250));
    final i = _doses.indexWhere((d) => d.id == doseId);
    if (i < 0) {
      throw ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'La dosis solicitada no existe.',
      );
    }
    final updated =
        _doses[i].copyWith(status: status, loggedAt: DateTime.now());
    _doses[i] = updated;
    return updated;
  }

  @override
  Future<Adherence> adherence(String patientId,
      {DateTime? from, DateTime? to}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final end = to ?? DateTime.now();
    final days = from != null ? end.difference(from).inDays + 1 : 7;
    final byDay = <AdherencePoint>[];
    // Serie demo alrededor del 80%.
    const sample = [75.0, 100.0, 80.0, 60.0, 100.0, 80.0, 80.0];
    for (var i = 0; i < days; i++) {
      final d = end.subtract(Duration(days: days - 1 - i));
      byDay.add(AdherencePoint(date: d, pct: sample[i % sample.length]));
    }
    return Adherence(
      pct: 80,
      byDay: byDay,
      byMedication: const [
        MedicationAdherence(
            medicationId: 'm-losartan', medicationName: 'Losartán', pct: 90),
        MedicationAdherence(
            medicationId: 'm-metformina',
            medicationName: 'Metformina',
            pct: 72),
        MedicationAdherence(
            medicationId: 'm-atorvastatina',
            medicationName: 'Atorvastatina',
            pct: 78),
      ],
    );
  }

  @override
  Future<PrescriptionDraft> scanPrescription(
      String patientId, String fileUrl) async {
    await Future.delayed(const Duration(milliseconds: 900));
    final today = DateTime.now();
    return PrescriptionDraft(
      medications: [
        NewMedication(
          name: 'Enalapril',
          dose: '10',
          unit: 'mg',
          form: 'comprimido',
          schedule: const ['09:00'],
          instructions: 'Tomar una vez al día por la mañana.',
          startDate: today,
        ),
        NewMedication(
          name: 'Omeprazol',
          dose: '20',
          unit: 'mg',
          form: 'cápsula',
          schedule: const ['08:00'],
          instructions: 'Tomar en ayunas antes del desayuno.',
          startDate: today,
        ),
      ],
    );
  }
}

String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final medicationsRepositoryProvider = Provider<MedicationsRepository>((ref) {
  if (AppConfig.useMocks) return MedicationsRepositoryMock();
  return MedicationsRepositoryHttp(ref.watch(apiClientProvider));
});

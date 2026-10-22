import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/domain/models.dart';
import '../../patients/domain/models.dart';
import '../domain/models.dart';

abstract class DashboardRepository {
  /// Resumen del día del paciente (semáforo, highlights, adherencia, vitals).
  Future<TodaySummary> todaySummary(String patientId);

  /// Tablero multi-paciente del usuario actual.
  Future<List<PatientCard>> dashboard();
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class DashboardRepositoryHttp implements DashboardRepository {
  DashboardRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<TodaySummary> todaySummary(String patientId) async {
    final data =
        await _api.get<Map<String, dynamic>>('/patients/$patientId/summary/today');
    return TodaySummary.fromJson(data);
  }

  @override
  Future<List<PatientCard>> dashboard() async {
    final data = await _api.get<Map<String, dynamic>>('/users/me/dashboard');
    return ((data['items'] ?? []) as List)
        .map((e) => PatientCard.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class DashboardRepositoryMock implements DashboardRepository {
  @override
  Future<TodaySummary> todaySummary(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 350));

    // José: paciente con datos de wearable desactualizados.
    if (patientId == 'p-jose') {
      return TodaySummary(
        wellbeingStatus: WellbeingStatus.attention,
        statusReasons: const ['Wearable sin datos desde hace 3 h'],
        activeAlerts: const [
          ActiveAlertBrief(
            id: 'a-jose-1',
            type: 'wearable_offline',
            severity: 'warning',
            title: 'Wearable sin datos',
            detail: 'Sin lecturas desde hace 3 h.',
          ),
        ],
        medicationsToday:
            const MedicationsToday(taken: 1, pending: 0, missed: 1),
        latestVitals: [
          VitalReading(
            type: 'heart_rate',
            value: '68',
            unit: 'lpm',
            measuredAt: DateTime.now().subtract(const Duration(hours: 3)),
          ),
          VitalReading(
            type: 'steps',
            value: '640',
            unit: 'pasos',
            measuredAt: DateTime.now().subtract(const Duration(hours: 3)),
          ),
        ],
      );
    }

    // Elena (por defecto): semáforo warning por ritmo cardíaco elevado.
    return TodaySummary(
      wellbeingStatus: WellbeingStatus.warning,
      statusReasons: const ['1 dosis omitida(s) hoy'],
      activeAlerts: const [
        ActiveAlertBrief(
          id: 'a-elena-1',
          type: 'missed_dose',
          severity: 'warning',
          title: 'Medicamento no tomado',
          detail: 'Losartán 50 mg de las 14:00 fuera de ventana.',
        ),
      ],
      medicationsToday: MedicationsToday(
        taken: 2,
        pending: 0,
        missed: 1,
        nextDose: DateTime.now().copyWith(hour: 21, minute: 0),
      ),
      latestVitals: [
        VitalReading(
          type: 'heart_rate',
          value: '72',
          unit: 'lpm',
          measuredAt: DateTime.now().subtract(const Duration(minutes: 6)),
        ),
        VitalReading(
          type: 'spo2',
          value: '96',
          unit: '%',
          measuredAt: DateTime.now().subtract(const Duration(minutes: 6)),
        ),
        VitalReading(
          type: 'steps',
          value: '2340',
          unit: 'pasos',
          measuredAt: DateTime.now().subtract(const Duration(minutes: 25)),
        ),
      ],
    );
  }

  @override
  Future<List<PatientCard>> dashboard() async {
    await Future.delayed(const Duration(milliseconds: 350));
    return const [
      PatientCard(
        patientId: 'p-elena',
        fullName: 'Elena Ramírez',
        role: RoleType.family,
        wellbeingStatus: WellbeingStatus.warning,
        activeAlertsCount: 1,
        topReason: 'Ritmo cardíaco elevado esta tarde',
      ),
      PatientCard(
        patientId: 'p-jose',
        fullName: 'José Ramírez',
        role: RoleType.family,
        wellbeingStatus: WellbeingStatus.attention,
        activeAlertsCount: 1,
        topReason: 'Wearable sin datos desde hace 3 h',
      ),
    ];
  }
}

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  if (AppConfig.useMocks) return DashboardRepositoryMock();
  return DashboardRepositoryHttp(ref.watch(apiClientProvider));
});

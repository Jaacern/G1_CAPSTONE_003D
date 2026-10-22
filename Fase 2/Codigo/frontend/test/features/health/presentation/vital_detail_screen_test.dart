// Pruebas del detalle de un vital: selector de rango 7/30/90 días y
// gráfica de tendencia con mínimos/máximos (AGE-304 / DAC05-62).
//
// Cubre el criterio de aceptación AC2 del ticket: al cambiar el filtro de
// tendencia, la gráfica se actualiza mostrando mínimos y máximos. El rango
// se mantiene en 7/30/90 días (implementación ya existente), no 24h/7días
// como decía el texto original del ticket.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/health/domain/models.dart';
import 'package:agecare_app/features/health/presentation/vital_detail_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:flutter/material.dart' hide Threshold;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Repositorio de pacientes con un único paciente, para que
/// selectedPatientProvider se auto-seleccione sin ambigüedad.
class _SinglePatientRepo implements PatientsRepository {
  static const _only = PatientCard(
    patientId: 'p-test',
    fullName: 'Paciente de prueba',
    role: RoleType.family,
    wellbeingStatus: WellbeingStatus.ok,
  );

  @override
  Future<List<PatientCard>> listMyPatients() async => const [_only];

  @override
  Future<Patient> getPatient(String patientId) => throw UnimplementedError();

  @override
  Future<Patient> createPatient(NewPatient data) => throw UnimplementedError();

  @override
  Future<Invitation> invite(
          {required String patientId, required RoleType role, String? email}) =>
      throw UnimplementedError();

  @override
  Future<PatientCard> acceptInvitation(String code) =>
      throw UnimplementedError();

  @override
  Future<WearableStatus> wearableStatus(String patientId) =>
      throw UnimplementedError();
}

/// Repositorio de vitals que registra el rango (en días) solicitado en cada
/// llamada a getSeries, para comprobar que cambiar el selector dispara una
/// nueva consulta con el rango correcto. Siempre devuelve mínimos/máximos
/// para poder comprobar la leyenda del AC2.
class _RecordingVitalsRepo implements VitalsRepository {
  final List<int> requestedDays = [];

  @override
  Future<VitalSeries> getSeries(
    String patientId,
    VitalType type, {
    required DateTime from,
    required DateTime to,
    String granularity = 'day',
  }) async {
    final days = to.difference(from).inDays;
    requestedDays.add(days);
    return VitalSeries(
      type: type,
      points: [
        for (var i = 0; i <= days; i++)
          VitalPoint(
            ts: from.add(Duration(days: i)),
            value: 70 + i.toDouble(),
            min: 60 + i.toDouble(),
            max: 80 + i.toDouble(),
          ),
      ],
      threshold:
          const Threshold(type: VitalType.heartRate, minValue: 50, maxValue: 110),
    );
  }

  @override
  Future<List<LatestVital>> getLatest(String patientId) async => [];

  @override
  Future<List<Threshold>> getThresholds(String patientId) async => [];

  @override
  Future<Threshold> setThreshold(
    String patientId,
    VitalType type, {
    double? minValue,
    double? maxValue,
  }) async =>
      Threshold(type: type, minValue: minValue, maxValue: maxValue);

  @override
  Future<int> uploadBatch(String patientId, List<VitalReading> readings) =>
      throw UnimplementedError();
}

void main() {
  Future<_RecordingVitalsRepo> pumpDetail(WidgetTester tester) async {
    final repo = _RecordingVitalsRepo();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider.overrideWithValue(_SinglePatientRepo()),
        vitalsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const VitalDetailScreen(typeApiValue: 'heart_rate'),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    return repo;
  }

  testWidgets(
      'muestra la leyenda de mínimos/máximos y el umbral, coincidiendo con el wireframe',
      (tester) async {
    final repo = await pumpDetail(tester);

    expect(repo.requestedDays, [7]); // rango por defecto
    expect(
        find.text('Línea: promedio del día · banda: rango mín–máx'),
        findsOneWidget);
    expect(find.textContaining('Umbral de alerta'), findsOneWidget);
  });

  testWidgets(
      'al cambiar el filtro de tendencia (7/30/90 días), la gráfica se actualiza con el nuevo rango (AC2)',
      (tester) async {
    final repo = await pumpDetail(tester);
    expect(repo.requestedDays.last, 7);

    await tester.tap(find.text('30 días'));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(repo.requestedDays.last, 30);

    await tester.tap(find.text('90 días'));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(repo.requestedDays.last, 90);
    // En 90 días la agregación es semanal.
    expect(find.textContaining('promedio semanal'), findsOneWidget);

    await tester.tap(find.text('7 días'));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(repo.requestedDays.last, 7);

    // Al volver a 7 días, vuelve a la leyenda diaria con banda mín–máx.
    expect(
        find.text('Línea: promedio del día · banda: rango mín–máx'),
        findsOneWidget);
  });
}

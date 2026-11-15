// El resumen del dia de un paciente (GET /patients/{id}/summary/today).
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/home/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('se lee completo de la API', () {
    final r = TodaySummary.fromJson(const {
      'wellbeing_status': 'attention',
      'status_reasons': ['spo2 fuera de rango (88.0 %)'],
      'active_alerts': [
        {
          'id': 'a-1',
          'type': 'vital_out_of_range',
          'severity': 'critical',
          'title': 'Saturación baja',
        },
      ],
      'latest_vitals': [
        {'type': 'spo2', 'value': 88.0, 'unit': '%', 'in_range': false},
      ],
      'medications_today': {'taken': 1, 'pending': 1, 'missed': 0},
    });

    expect(r.wellbeingStatus, WellbeingStatus.attention);
    expect(r.topReason, 'SpO₂ fuera de rango (88 %)');
    expect(r.hasAlerts, isTrue);
    expect(r.activeAlerts.single.isCritical, isTrue);
    expect(r.latestVitals.single.display, '88 %');
    expect(r.adherencePct, 50);
  });

  test('con la respuesta minima no falla y queda todo en orden', () {
    final r = TodaySummary.fromJson(const {});

    expect(r.wellbeingStatus, WellbeingStatus.ok);
    expect(r.topReason, isNull);
    expect(r.activeAlertsCount, 0);
    expect(r.adherencePct, 100);
  });
}

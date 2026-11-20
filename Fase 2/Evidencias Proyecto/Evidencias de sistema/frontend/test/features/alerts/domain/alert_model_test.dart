// El payload de una alerta es jsonb libre y 'acknowledged_by' es un id de
// usuario. Estas pruebas fijan cómo se traduce ese JSON a la ficha de la alerta.
import 'package:agecare_app/features/alerts/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json({Object? payload}) => {
      'alert_id': '7c9e6679-7425-40de-944b-e07fc1f90ae7',
      'patient_id': 'p-elena',
      'patient_name': 'Elena Ramírez',
      'type': 'vital_out_of_range',
      'severity': 'warning',
      'title': 'Ritmo cardíaco elevado',
      'detail': 'La FC superó el umbral.',
      'status': 'acknowledged',
      'created_at': '2026-11-01T10:15:00+00:00',
      'acknowledged_by': '3f2a1b6c-0d4e-5f6a-7b8c-9d0e1f2a3b4c',
      'resolved_at': null,
      if (payload != null) 'payload': payload,
    };

void main() {
  test('un payload objeto llega como mapa de detalles', () {
    final a = Alert.fromJson(
        _json(payload: {'value': 124, 'unit': 'bpm', 'threshold': 120}));

    expect(a.meta, {'value': 124, 'unit': 'bpm', 'threshold': 120});
    expect(a.message, 'La FC superó el umbral.');
    expect(a.id, '7c9e6679-7425-40de-944b-e07fc1f90ae7');
  });

  test('un payload lista no rompe la lectura de la alerta', () {
    // AlertItem declara payload como dict | list.
    final a = Alert.fromJson(_json(payload: [
      {'value': 124}
    ]));

    expect(a.meta, isNull);
    expect(a.title, 'Ritmo cardíaco elevado');
  });

  test('un payload que el backend no pudo parsear no rompe la alerta', () {
    // _parse_payload devuelve el string crudo cuando el JSON no es válido.
    final a = Alert.fromJson(_json(payload: 'no-es-json'));

    expect(a.meta, isNull);
    expect(a.isActive, isFalse);
  });

  test('el id de quien reconoció no se muestra como si fuera su nombre', () {
    final a = Alert.fromJson(_json());

    expect(a.acknowledgedBy, isNull);
    expect(a.status, AlertStatus.acknowledged);
  });
}

// Cada vez que se da un SOS queda registrado con la hora y el motivo.
import 'package:agecare_app/features/medications/domain/_prn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el SOS se lee de la API con sus limites', () {
    final sos = PrnItem.fromJson(const {
      'item_id': 'i-1',
      'name': 'Paracetamol',
      'dose': '1 comprimido',
      'dose_amount': 1,
      'dose_unit': 'comprimido',
      'min_interval_min': 480,
      'max_daily': 4,
      'last_used_at': '2026-11-12T08:00:00Z',
      'uses_last_24h': 2,
      'used_last_24h': 2,
    });

    expect(sos.specialty, 'general');
    expect(sos.maxDaily, 4.0);
    expect(sos.usesLast24h, 2);
    expect(sos.lastUsedAt, isNotNull);
    expect(sos.intervaloLegible, 'cada 8 h');
  });

  test('un uso registrado guarda quien lo dio y si se adelanto', () {
    final uso = PrnUse.fromJson(const {
      'use_id': 'u-1',
      'item_id': 'i-1',
      'name': 'Paracetamol',
      'dose': '1 comprimido',
      'administered_at': '2026-11-12T14:30:00Z',
      'reason': 'Dolor de cabeza',
      'logged_by_name': 'Marisol Tapia',
      'overrode_interval': true,
    });

    expect(uso.reason, 'Dolor de cabeza');
    expect(uso.loggedByName, 'Marisol Tapia');
    expect(uso.overrodeInterval, isTrue);
    expect(uso.administeredAt.isUtc, isFalse); // en la hora local
  });

  test('si falta el aviso de adelanto se asume que no se adelanto', () {
    final uso = PrnUse.fromJson(const {
      'use_id': 'u-2',
      'item_id': 'i-1',
      'name': 'Paracetamol',
      'administered_at': '2026-11-12T14:30:00Z',
    });

    expect(uso.overrodeInterval, isFalse);
    expect(uso.reason, '');
  });
}

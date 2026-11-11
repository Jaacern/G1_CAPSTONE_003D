import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/timeline.dart';

/// Historial del paciente por páginas (GET /patients/{id}/timeline).
abstract class TimelineRepository {
  Future<TimelinePage> page(
    String patientId, {
    String? cursor,
    int limit = 20,
    List<TimelineKind> kinds = const [],
  });
}

class TimelineRepositoryHttp implements TimelineRepository {
  TimelineRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<TimelinePage> page(
    String patientId, {
    String? cursor,
    int limit = 20,
    List<TimelineKind> kinds = const [],
  }) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/timeline',
      query: {
        'limit': limit,
        if (cursor != null) 'cursor': cursor,
        // Dio repite la clave por cada valor: kinds=dose&kinds=prn.
        if (kinds.isNotEmpty) 'kinds': kinds.map((k) => k.apiValue).toList(),
      },
    );
    return TimelinePage(
      items: ((data['items'] ?? const []) as List)
          .map((e) => TimelineEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: data['next_cursor'] as String?,
    );
  }
}

/// Historial simulado: 30 días de eventos estables por paciente, para poder
/// mostrar el scroll y los filtros sin backend.
class TimelineRepositoryMock implements TimelineRepository {
  final Map<String, List<TimelineEvent>> _cache = {};

  List<TimelineEvent> _eventos(String patientId) =>
      _cache.putIfAbsent(patientId, () {
        final ahora = DateTime.now();
        final out = <TimelineEvent>[];
        var n = 0;
        TimelineEvent ev(TimelineKind k, Duration hace, String titulo,
                {String? sub,
                String? sev,
                String? det,
                String? autor,
                double? v,
                double? v2,
                String? unidad}) =>
            TimelineEvent(
              id: '$patientId-${n++}',
              kind: k,
              ts: ahora.subtract(hace),
              title: titulo,
              subtype: sub,
              severity: sev,
              detail: det,
              author: autor,
              value: v,
              valueSecondary: v2,
              unit: unidad,
            );
        for (var d = 0; d < 30; d++) {
          final dia = Duration(days: d);
          out.add(ev(
              TimelineKind.dose, dia + const Duration(hours: 2), 'Losartán',
              sub: d % 9 == 4 ? 'missed' : 'taken',
              sev: d % 9 == 4 ? 'warning' : null,
              det: '50 mg · programada 08:00',
              autor: d % 9 == 4 ? null : 'Marisol Tapia'));
          if (d % 2 == 0) {
            out.add(ev(TimelineKind.vital, dia + const Duration(hours: 3),
                'Presión arterial',
                sub: 'blood_pressure',
                sev: d % 6 == 0 ? 'warning' : null,
                det: 'Medición manual',
                autor: 'Marisol Tapia',
                v: d % 6 == 0 ? 148 : 128,
                v2: d % 6 == 0 ? 92 : 80,
                unidad: 'mmHg'));
          }
          if (d % 3 == 1) {
            out.add(ev(TimelineKind.observation, dia + const Duration(hours: 5),
                'Almorzó completo y salió a caminar por la plaza.',
                sub: 'food', autor: 'Marisol Tapia'));
          }
          if (d % 7 == 3) {
            out.add(ev(TimelineKind.vital, dia + const Duration(hours: 9),
                'Saturación O₂',
                sub: 'spo2',
                sev: 'warning',
                det: 'Reloj · fuera del rango del paciente',
                v: 89,
                unidad: '%'));
            out.add(ev(TimelineKind.alert, dia + const Duration(hours: 9),
                'Saturación bajo el mínimo',
                sub: 'vital_out_of_range',
                sev: 'warning',
                det: 'SpO2 89% (mínimo configurado 92%).'));
          }
        }
        out.add(ev(TimelineKind.treatment, const Duration(days: 20),
            'Tratamiento modificado',
            sub: 'cardiologia',
            det: 'Losartán 50 mg, Aspirina 100 mg',
            autor: 'Dra. Carolina Soto'));
        out.sort((a, b) => b.ts.compareTo(a.ts));
        return out;
      });

  @override
  Future<TimelinePage> page(
    String patientId, {
    String? cursor,
    int limit = 20,
    List<TimelineKind> kinds = const [],
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final todos = _eventos(patientId)
        .where((e) => kinds.isEmpty || kinds.contains(e.kind))
        .toList();
    final desde = cursor == null ? 0 : int.parse(cursor);
    final hasta = (desde + limit).clamp(0, todos.length);
    return TimelinePage(
      items: todos.sublist(desde, hasta),
      nextCursor: hasta < todos.length ? '$hasta' : null,
    );
  }
}

final timelineRepositoryProvider = Provider<TimelineRepository>((ref) {
  if (AppConfig.useMocks) return TimelineRepositoryMock();
  return TimelineRepositoryHttp(ref.watch(apiClientProvider));
});

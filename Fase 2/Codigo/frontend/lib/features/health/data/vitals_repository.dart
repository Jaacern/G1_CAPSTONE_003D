import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

abstract class VitalsRepository {
  /// Sube un lote de lecturas (endpoint 5.1). Devuelve las aceptadas.
  Future<int> uploadBatch(String patientId, List<VitalReading> readings);

  /// Serie de un vital con agregación (endpoint 5.3).
  Future<VitalSeries> getSeries(
    String patientId,
    VitalType type, {
    required DateTime from,
    required DateTime to,
    String granularity = 'day',
  });

  /// Últimos valores por vital (endpoint 5.4).
  Future<List<LatestVital>> getLatest(String patientId);

  /// Umbrales (rangos normales) del paciente (endpoint 5.5).
  Future<List<Threshold>> getThresholds(String patientId);

  /// Configura el umbral de un vital (endpoint 5.6, roles family/doctor).
  /// Al menos uno de min/max debe venir; el backend valida min < max.
  Future<Threshold> setThreshold(
    String patientId,
    VitalType type, {
    double? minValue,
    double? maxValue,
  });
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class VitalsRepositoryHttp implements VitalsRepository {
  VitalsRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<int> uploadBatch(String patientId, List<VitalReading> readings) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/vitals/batch',
      data: {'readings': readings.map((r) => r.toJson()).toList()},
    );
    return (res['accepted'] ?? 0) as int;
  }

  @override
  Future<VitalSeries> getSeries(
    String patientId,
    VitalType type, {
    required DateTime from,
    required DateTime to,
    String granularity = 'day',
  }) async {
    String d(DateTime x) =>
        '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final res = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/vitals',
      query: {
        'type': type.apiValue,
        'date_from': d(from),
        'date_to': d(to),
        'granularity': granularity,
      },
    );
    final srcRaw = (res['sources'] ?? const {}) as Map<String, dynamic>;
    final sources = <VitalSource, int>{};
    srcRaw.forEach((k, v) {
      sources[VitalSource.resolve(k, k)] = (v as num).toInt();
    });
    return VitalSeries(
      type: type,
      points: ((res['points'] ?? []) as List)
          .map((p) => VitalPoint.fromJson(p as Map<String, dynamic>))
          .toList(),
      threshold: res['threshold'] != null
          ? Threshold.fromJson(res['threshold'] as Map<String, dynamic>)
          : null,
      sources: sources,
    );
  }

  @override
  Future<List<LatestVital>> getLatest(String patientId) async {
    final res =
        await _api.get<Map<String, dynamic>>('/patients/$patientId/vitals/latest');
    return ((res['items'] ?? []) as List)
        .map((e) => LatestVital.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<Threshold>> getThresholds(String patientId) async {
    final res = await _api
        .get<Map<String, dynamic>>('/patients/$patientId/vitals/thresholds');
    return ((res['items'] ?? []) as List)
        .map((e) => Threshold.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Threshold> setThreshold(
    String patientId,
    VitalType type, {
    double? minValue,
    double? maxValue,
  }) async {
    final res = await _api.put<Map<String, dynamic>>(
      '/patients/$patientId/vitals/thresholds/${type.apiValue}',
      data: {
        if (minValue != null) 'min_value': minValue,
        if (maxValue != null) 'max_value': maxValue,
      },
    );
    return Threshold.fromJson(res);
  }
}

// ---------------------------------------------------------------------------
// Mock: genera series realistas y estables por paciente (misma semilla).
// ---------------------------------------------------------------------------
class VitalsRepositoryMock implements VitalsRepository {
  final _uploaded = <String, List<VitalReading>>{};

  static const _thresholds = [
    Threshold(type: VitalType.heartRate, minValue: 50, maxValue: 110),
    Threshold(type: VitalType.spo2, minValue: 92),
    Threshold(type: VitalType.temperature, minValue: 36.1, maxValue: 37.2),
  ];

  Random _rng(String patientId, VitalType type) =>
      Random(patientId.hashCode ^ type.index);

  double _baseline(VitalType type) {
    switch (type) {
      case VitalType.heartRate:
        return 72;
      case VitalType.spo2:
        return 96;
      case VitalType.bloodPressure:
        return 120;
      case VitalType.temperature:
        return 36.6;
      case VitalType.glucose:
        return 95;
      case VitalType.sleep:
        return 6.8;
      case VitalType.steps:
        return 3200;
      case VitalType.sedentaryMin:
        return 540;
      case VitalType.fallEvent:
        return 0;
    }
  }

  double _jitter(VitalType type, Random rng) {
    switch (type) {
      case VitalType.heartRate:
        return rng.nextDouble() * 14 - 7;
      case VitalType.spo2:
        return rng.nextDouble() * 3 - 1.5;
      case VitalType.bloodPressure:
        return rng.nextDouble() * 20 - 10;
      case VitalType.temperature:
        return rng.nextDouble() * 0.8 - 0.4;
      case VitalType.glucose:
        return rng.nextDouble() * 30 - 15;
      case VitalType.sleep:
        return rng.nextDouble() * 2.4 - 1.2;
      case VitalType.steps:
        return rng.nextDouble() * 2400 - 1200;
      case VitalType.sedentaryMin:
        return rng.nextDouble() * 120 - 60;
      case VitalType.fallEvent:
        return 0;
    }
  }

  /// Media banda de variacion diaria (min/max) alrededor del valor, para que
  /// la grafica de tendencia pueda mostrar minimos y maximos (AGE-304).
  /// Proporcional al tipo de vital para que se vea razonable en el grafico.
  double _dailySpread(VitalType type) {
    switch (type) {
      case VitalType.heartRate:
        return 10;
      case VitalType.spo2:
        return 2;
      case VitalType.bloodPressure:
        return 8;
      case VitalType.temperature:
        return 0.3;
      case VitalType.glucose:
        return 15;
      case VitalType.sleep:
        return 0.6;
      case VitalType.steps:
        return 600;
      case VitalType.sedentaryMin:
        return 40;
      case VitalType.fallEvent:
        return 0;
    }
  }

  @override
  Future<int> uploadBatch(String patientId, List<VitalReading> readings) async {
    await Future.delayed(const Duration(milliseconds: 200));
    _uploaded.putIfAbsent(patientId, () => []).addAll(readings);
    return readings.length;
  }

  @override
  Future<VitalSeries> getSeries(
    String patientId,
    VitalType type, {
    required DateTime from,
    required DateTime to,
    String granularity = 'day',
  }) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final rng = _rng(patientId, type);
    final days = to.difference(from).inDays.clamp(1, 92);
    final points = <VitalPoint>[];
    for (var i = 0; i <= days; i++) {
      final day = from.add(Duration(days: i));
      final value =
          (_baseline(type) + _jitter(type, rng)).clamp(0, double.infinity);
      final spread = _dailySpread(type);
      points.add(VitalPoint(
        ts: day,
        value: double.parse(value.toStringAsFixed(1)),
        min: spread > 0
            ? double.parse((value - spread).clamp(0, double.infinity).toStringAsFixed(1))
            : null,
        max: spread > 0 ? double.parse((value + spread).toStringAsFixed(1)) : null,
      ));
    }
    Threshold? threshold;
    for (final t in _thresholds) {
      if (t.type == type) threshold = t;
    }
    return VitalSeries(type: type, points: points, threshold: threshold);
  }

  @override
  Future<List<LatestVital>> getLatest(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 250));
    final now = DateTime.now();
    // 'p-jose' simula SpO2 baja para demostrar el indicador de fuera de
    // rango (AC1).
    final lowSpo2 = patientId == 'p-jose';
    const hrValue = 74.0;
    final spo2Value = lowSpo2 ? 91.0 : 97.0;
    const tempValue = 36.7;
    return [
      LatestVital(
          type: VitalType.heartRate,
          value: hrValue,
          measuredAt: now.subtract(const Duration(minutes: 12)),
          inRange: _inRange(VitalType.heartRate, hrValue),
          source: VitalSource.simulator),
      LatestVital(
          type: VitalType.spo2,
          value: spo2Value,
          measuredAt: now.subtract(const Duration(minutes: 12)),
          inRange: _inRange(VitalType.spo2, spo2Value),
          source: VitalSource.simulator),
      LatestVital(
          type: VitalType.temperature,
          value: tempValue,
          measuredAt: now.subtract(const Duration(minutes: 12)),
          inRange: _inRange(VitalType.temperature, tempValue),
          source: VitalSource.simulator),
      LatestVital(
          type: VitalType.sleep,
          value: 6.5,
          measuredAt: DateTime(now.year, now.month, now.day, 7),
          source: VitalSource.simulator),
      LatestVital(
          type: VitalType.steps,
          value: 2840,
          measuredAt: now.subtract(const Duration(minutes: 30)),
          source: VitalSource.simulator),
    ];
  }

  /// Umbrales editados en modo prueba (sobrescriben los `_thresholds` base),
  /// por paciente y tipo. Permite demostrar la edición sin backend.
  final Map<String, Map<VitalType, Threshold>> _overrides = {};

  List<Threshold> _effectiveThresholds(String patientId) {
    final base = {for (final t in _thresholds) t.type: t};
    final ov = _overrides[patientId];
    if (ov != null) base.addAll(ov);
    return base.values.toList();
  }

  /// Compara un valor contra el umbral médico normal del tipo (AC1:
  /// "...indicadores de estado según rangos médicos normales"). Sin
  /// umbral definido para el tipo, se asume en rango (ej. sueño, pasos).
  bool _inRange(VitalType type, double value) {
    for (final t in _thresholds) {
      if (t.type == type) return !t.isOutOfRange(value);
    }
    return true;
  }

  @override
  Future<List<Threshold>> getThresholds(String patientId) async =>
      _effectiveThresholds(patientId);

  @override
  Future<Threshold> setThreshold(
    String patientId,
    VitalType type, {
    double? minValue,
    double? maxValue,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final t = Threshold(type: type, minValue: minValue, maxValue: maxValue);
    _overrides.putIfAbsent(patientId, () => {})[type] = t;
    return t;
  }
}

final vitalsRepositoryProvider = Provider<VitalsRepository>((ref) {
  if (AppConfig.useMocks) return VitalsRepositoryMock();
  return VitalsRepositoryHttp(ref.watch(apiClientProvider));
});

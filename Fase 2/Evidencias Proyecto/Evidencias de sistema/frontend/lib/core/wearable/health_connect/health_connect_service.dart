import 'package:health/health.dart';

import '../../../features/health/domain/models.dart' as domain;

/// Resultado de una lectura de Health Connect, listo para subir al backend.
class HealthReadResult {
  const HealthReadResult({
    required this.readings,
    required this.rawCount,
    this.note,
  });

  /// Lecturas ya mapeadas al modelo del backend (type/value/measured_at).
  final List<domain.VitalReading> readings;

  /// Cuántos puntos crudos trajo Health Connect antes de agregar/mapear.
  final int rawCount;

  /// Mensaje informativo (p. ej. "sin datos en el rango").
  final String? note;
}

/// Servicio para leer datos de salud reales desde **Health Connect** (Android)
/// o **HealthKit** (iOS) usando el paquete `health`.
///
/// Flujo pensado para un reloj real (Samsung Galaxy Watch 4 → Samsung Health →
/// Health Connect → esta app → backend `/vitals/batch`):
///  1. [isAvailable] comprueba que Health Connect esté instalado/soportado.
///  2. [requestPermissions] pide permiso de LECTURA de las métricas de AgeCare.
///  3. [readVitals] lee el rango de fechas y mapea al modelo del backend.
///
/// NO sube nada por sí mismo: devuelve las lecturas y el
/// `HealthConnectSyncController` se encarga del POST al backend. Así el servicio
/// queda testeable y con una sola responsabilidad.
class HealthConnectService {
  HealthConnectService({Health? health}) : _health = health ?? Health();

  final Health _health;
  bool _configured = false;

  /// Tipos de salud que AgeCare necesita del adulto mayor.
  /// (El Galaxy Watch 4 reporta ritmo, pasos, SpO₂ y sueño vía Samsung Health.)
  static const List<HealthDataType> _types = [
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.BLOOD_OXYGEN, // SpO₂
    HealthDataType.SLEEP_ASLEEP,
  ];

  static const List<HealthDataAccess> _access = [
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
  ];

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    // Configura el canal nativo del plugin. Idempotente.
    await _health.configure();
    _configured = true;
  }

  /// ¿Health Connect está disponible/soportado en este dispositivo?
  /// En Android retorna el estado de la app Health Connect; en iOS asume
  /// HealthKit disponible.
  Future<bool> isAvailable() async {
    await _ensureConfigured();
    try {
      final status = await _health.getHealthConnectSdkStatus();
      return status == HealthConnectSdkStatus.sdkAvailable;
    } catch (_) {
      // En iOS (HealthKit) el método anterior no aplica; se asume disponible.
      return true;
    }
  }

  /// Abre la tienda para instalar/actualizar Health Connect (solo Android).
  Future<void> installHealthConnect() async {
    await _ensureConfigured();
    try {
      await _health.installHealthConnect();
    } catch (_) {/* iOS u otros: no aplica */}
  }

  /// Solicita permisos de LECTURA. Devuelve true si quedaron concedidos.
  Future<bool> requestPermissions() async {
    await _ensureConfigured();
    final already = await _health.hasPermissions(_types, permissions: _access);
    if (already == true) return true;
    return _health.requestAuthorization(_types, permissions: _access);
  }

  /// Lee las métricas entre [from] y [to] y las mapea al modelo del backend.
  ///
  /// Reglas de mapeo:
  /// - heart_rate / spo2 → un `VitalReading` por muestra (valor puntual).
  /// - steps → el backend espera pasos acumulados; Health Connect los entrega
  ///   por intervalos. Se suma por día y se emite un punto diario.
  /// - sleep → se convierte la duración de cada sesión a HORAS.
  Future<HealthReadResult> readVitals({
    required DateTime from,
    required DateTime to,
  }) async {
    await _ensureConfigured();

    final raw = await _health.getHealthDataFromTypes(
      types: _types,
      startTime: from,
      endTime: to,
    );
    final deduped = _health.removeDuplicates(raw);

    final readings = <domain.VitalReading>[];
    final stepsByDay = <DateTime, double>{};
    // Etiqueta de origen: queda guardada en vital_readings.meta para distinguir
    // lecturas reales del reloj de los datos de prueba del simulador.
    const meta = {'origin': 'health_connect'};

    for (final p in deduped) {
      final value = _numericValue(p.value);
      if (value == null) continue;

      switch (p.type) {
        case HealthDataType.HEART_RATE:
          readings.add(domain.VitalReading(
            type: domain.VitalType.heartRate,
            value: value,
            measuredAt: p.dateTo,
            meta: meta,
          ));
          break;
        case HealthDataType.BLOOD_OXYGEN:
          // Health Connect entrega fracción (0–1) o porcentaje según fuente.
          final pct = value <= 1.0 ? value * 100 : value;
          readings.add(domain.VitalReading(
            type: domain.VitalType.spo2,
            value: double.parse(pct.toStringAsFixed(1)),
            measuredAt: p.dateTo,
            meta: meta,
          ));
          break;
        case HealthDataType.STEPS:
          final day = DateTime(p.dateTo.year, p.dateTo.month, p.dateTo.day);
          stepsByDay[day] = (stepsByDay[day] ?? 0) + value;
          break;
        case HealthDataType.SLEEP_ASLEEP:
          // Duración de la sesión de sueño (en minutos) → horas.
          final minutes = p.dateTo.difference(p.dateFrom).inMinutes.toDouble();
          if (minutes > 0) {
            readings.add(domain.VitalReading(
              type: domain.VitalType.sleep,
              value: double.parse((minutes / 60).toStringAsFixed(2)),
              measuredAt: p.dateTo,
              meta: meta,
            ));
          }
          break;
        default:
          break;
      }
    }

    // Un punto de pasos por día (medido al final del día).
    stepsByDay.forEach((day, total) {
      readings.add(domain.VitalReading(
        type: domain.VitalType.steps,
        value: total.roundToDouble(),
        measuredAt: day.add(const Duration(hours: 22)),
        meta: meta,
      ));
    });

    // Orden cronológico para una ingesta limpia.
    readings.sort((a, b) => a.measuredAt.compareTo(b.measuredAt));

    return HealthReadResult(
      readings: readings,
      rawCount: deduped.length,
      note: readings.isEmpty
          ? 'No se encontraron datos en el rango. ¿El reloj sincronizó con '
              'Samsung Health y este con Health Connect?'
          : null,
    );
  }

  /// Extrae el número de un HealthValue (soporta Numeric; ignora el resto).
  double? _numericValue(HealthValue v) {
    if (v is NumericHealthValue) {
      return v.numericValue.toDouble();
    }
    return null;
  }
}

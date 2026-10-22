import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Estado de una dosis (alineado con la API).
enum DoseStatus {
  pending('pending', 'Pendiente', AppColors.textSecondary),
  taken('taken', 'Tomada', AppColors.statusOk),
  skipped('skipped', 'Omitida', AppColors.statusWarning),
  missed('missed', 'No tomada', AppColors.statusAttention);

  const DoseStatus(this.apiValue, this.label, this.color);

  final String apiValue;
  final String label;
  final Color color;

  static DoseStatus fromApi(String value) => DoseStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => DoseStatus.pending,
      );
}

/// Medicamento del plan del paciente.
class Medication {
  const Medication({
    required this.id,
    required this.name,
    required this.dose,
    required this.unit,
    required this.form,
    this.schedule = const [],
    this.instructions,
    this.active = true,
    required this.startDate,
    this.endDate,
  });

  final String id;
  final String name;

  /// Cantidad por toma (p. ej. "50", "1").
  final String dose;

  /// Unidad de la dosis (p. ej. "mg", "ml", "comprimido").
  final String unit;

  /// Forma farmacéutica (p. ej. "comprimido", "cápsula", "jarabe").
  final String form;

  /// Horarios de toma en formato 'HH:mm' (o descripciones de frecuencia).
  final List<String> schedule;

  final String? instructions;
  final bool active;
  final DateTime startDate;
  final DateTime? endDate;

  /// Texto legible del horario para mostrar en la UI.
  String get scheduleLabel =>
      schedule.isEmpty ? 'Sin horario definido' : schedule.join(' · ');

  /// Texto legible de la dosis (p. ej. "50 mg · comprimido").
  String get doseLabel => '$dose $unit · $form';

  Medication copyWith({
    String? name,
    String? dose,
    String? unit,
    String? form,
    List<String>? schedule,
    String? instructions,
    bool? active,
    DateTime? startDate,
    DateTime? endDate,
  }) =>
      Medication(
        id: id,
        name: name ?? this.name,
        dose: dose ?? this.dose,
        unit: unit ?? this.unit,
        form: form ?? this.form,
        schedule: schedule ?? this.schedule,
        instructions: instructions ?? this.instructions,
        active: active ?? this.active,
        startDate: startDate ?? this.startDate,
        endDate: endDate ?? this.endDate,
      );

  factory Medication.fromJson(Map<String, dynamic> json) => Medication(
        id: (json['id'] ?? json['medication_id']).toString(),
        name: json['name'] as String,
        // Backend: dose_amount (num) + dose_unit. Fallback a dose/unit (mock).
        dose: (json['dose_amount'] ?? json['dose'] ?? '').toString(),
        unit: (json['dose_unit'] ?? json['unit'] ?? '').toString(),
        // Backend no tiene 'form'; se mantiene por compat con el mock.
        form: (json['form'] ?? '').toString(),
        // Backend: times (["HH:MM"]). Fallback a schedule (mock).
        schedule: ((json['times'] ?? json['schedule'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        instructions: json['instructions'] as String?,
        // Backend: is_active. Fallback a active (mock).
        active: (json['is_active'] ?? json['active'] ?? true) as bool,
        startDate: json['start_date'] != null
            ? DateTime.parse(json['start_date'] as String)
            : DateTime.now(),
        endDate: json['end_date'] != null
            ? DateTime.parse(json['end_date'] as String)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'dose': dose,
        'unit': unit,
        'form': form,
        'schedule': schedule,
        if (instructions != null) 'instructions': instructions,
        'active': active,
        'start_date': _dateOnly(startDate),
        if (endDate != null) 'end_date': _dateOnly(endDate!),
      };
}

/// Dosis programada (una toma concreta en una fecha/hora).
class Dose {
  const Dose({
    required this.id,
    required this.medicationId,
    required this.medicationName,
    required this.scheduledAt,
    this.status = DoseStatus.pending,
    this.loggedAt,
    this.dose,
    this.unit,
  });

  final String id;
  final String medicationId;
  final String medicationName;
  final DateTime scheduledAt;
  final DoseStatus status;
  final DateTime? loggedAt;

  /// Cantidad y unidad para mostrar en la confirmación (opcional).
  final String? dose;
  final String? unit;

  String get timeLabel =>
      '${scheduledAt.hour.toString().padLeft(2, '0')}:${scheduledAt.minute.toString().padLeft(2, '0')}';

  Dose copyWith({DoseStatus? status, DateTime? loggedAt}) => Dose(
        id: id,
        medicationId: medicationId,
        medicationName: medicationName,
        scheduledAt: scheduledAt,
        status: status ?? this.status,
        loggedAt: loggedAt ?? this.loggedAt,
        dose: dose,
        unit: unit,
      );

  factory Dose.fromJson(Map<String, dynamic> json) => Dose(
        id: (json['id'] ?? json['dose_id']).toString(),
        medicationId: (json['medication_id'] ?? '').toString(),
        medicationName: (json['medication_name'] ?? '') as String,
        scheduledAt: DateTime.parse(json['scheduled_at'] as String),
        status: DoseStatus.fromApi((json['status'] ?? 'pending') as String),
        loggedAt: json['logged_at'] != null
            ? DateTime.parse(json['logged_at'] as String)
            : null,
        dose: json['dose']?.toString(),
        unit: json['unit']?.toString(),
      );
}

/// Solicitud de creación de un medicamento.
class NewMedication {
  const NewMedication({
    required this.name,
    required this.dose,
    required this.unit,
    required this.form,
    this.schedule = const [],
    this.instructions,
    required this.startDate,
    this.endDate,
  });

  final String name;
  final String dose;
  final String unit;
  final String form;
  final List<String> schedule;
  final String? instructions;
  final DateTime startDate;
  final DateTime? endDate;

  /// Serializa al contrato del backend (módulo 6):
  /// - `dose` (texto UI) -> `dose_amount` (float) + `dose_unit`
  /// - `schedule` (["HH:mm"]) -> `times`
  /// - `days_of_week`: todos los días (el backend asume todos si se omite,
  ///   pero lo enviamos explícito para que el plan sea claro)
  /// - `grace_window_min`: ventana de gracia por defecto (60 min)
  /// - `form` no existe en el backend: se preserva al inicio de las
  ///   instrucciones para no perder el dato clínico.
  Map<String, dynamic> toJson() {
    final doseAmount = double.tryParse(dose.replaceAll(',', '.')) ?? 0;
    final mergedInstructions = [
      if (form.isNotEmpty) 'Forma: $form',
      if (instructions != null && instructions!.trim().isNotEmpty)
        instructions!.trim(),
    ].join('. ');
    return {
      'name': name,
      'dose_amount': doseAmount,
      'dose_unit': unit,
      'times': schedule,
      'days_of_week': const [1, 2, 3, 4, 5, 6, 7],
      'grace_window_min': 60,
      if (mergedInstructions.isNotEmpty) 'instructions': mergedInstructions,
      'start_date': _dateOnly(startDate),
      if (endDate != null) 'end_date': _dateOnly(endDate!),
    };
  }
}

/// Un punto de adherencia por día.
class AdherencePoint {
  const AdherencePoint({required this.date, required this.pct});

  final DateTime date;
  final double pct;

  /// El backend (daily[]) entrega conteos {taken, missed, pending} por día,
  /// no un porcentaje; aquí lo calculamos: taken / (taken + missed).
  /// Mantiene fallback a 'pct' por compat con el mock.
  factory AdherencePoint.fromJson(Map<String, dynamic> json) {
    double pct;
    if (json['pct'] != null) {
      pct = (json['pct'] as num).toDouble();
    } else {
      final taken = (json['taken'] ?? 0) as int;
      final missed = (json['missed'] ?? 0) as int;
      final total = taken + missed;
      pct = total > 0 ? (taken / total) * 100 : 100;
    }
    return AdherencePoint(
      date: DateTime.parse(json['date'] as String),
      pct: pct,
    );
  }
}

/// Adherencia por medicamento.
class MedicationAdherence {
  const MedicationAdherence({
    required this.medicationId,
    required this.medicationName,
    required this.pct,
  });

  final String medicationId;
  final String medicationName;
  final double pct;

  factory MedicationAdherence.fromJson(Map<String, dynamic> json) =>
      MedicationAdherence(
        medicationId: (json['medication_id'] ?? '').toString(),
        // Backend: 'name'. Fallback a medication_name (mock).
        medicationName:
            (json['name'] ?? json['medication_name'] ?? '') as String,
        // Backend: adherence_pct. Fallback a pct (mock).
        pct: ((json['adherence_pct'] ?? json['pct']) as num).toDouble(),
      );
}

/// Resumen de adherencia del paciente en un rango.
class Adherence {
  const Adherence({
    required this.pct,
    this.byDay = const [],
    this.byMedication = const [],
  });

  final double pct;
  final List<AdherencePoint> byDay;
  final List<MedicationAdherence> byMedication;

  factory Adherence.fromJson(Map<String, dynamic> json) => Adherence(
        pct: (json['adherence_pct'] as num).toDouble(),
        // Backend: 'daily'. Fallback a by_day (mock).
        byDay: ((json['daily'] ?? json['by_day'] ?? []) as List)
            .map((e) => AdherencePoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        byMedication: ((json['by_medication'] ?? []) as List)
            .map((e) => MedicationAdherence.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Borrador de medicación sugerido por el OCR de una receta.
class PrescriptionDraft {
  const PrescriptionDraft({this.medications = const []});

  final List<NewMedication> medications;

  factory PrescriptionDraft.fromJson(Map<String, dynamic> json) =>
      PrescriptionDraft(
        medications: ((json['medications'] ?? []) as List)
            .map((e) => _newMedFromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ---------------------------------------------------------------------------
// Helpers privados
// ---------------------------------------------------------------------------
String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

NewMedication _newMedFromJson(Map<String, dynamic> json) => NewMedication(
      name: (json['name'] ?? '') as String,
      dose: (json['dose'] ?? '').toString(),
      unit: (json['unit'] ?? '').toString(),
      form: (json['form'] ?? '').toString(),
      schedule:
          ((json['schedule'] ?? []) as List).map((e) => e.toString()).toList(),
      instructions: json['instructions'] as String?,
      startDate: json['start_date'] != null
          ? DateTime.parse(json['start_date'] as String)
          : DateTime.now(),
      endDate: json['end_date'] != null
          ? DateTime.parse(json['end_date'] as String)
          : null,
    );

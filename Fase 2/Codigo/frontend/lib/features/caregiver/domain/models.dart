import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Estado de una tarea de cuidado (alineado con la API).
enum TaskStatus {
  pending('pending', 'Pendiente', AppColors.textSecondary),
  inProgress('in_progress', 'En curso', AppColors.statusWarning),
  done('done', 'Completada', AppColors.statusOk);

  const TaskStatus(this.apiValue, this.label, this.color);

  final String apiValue;
  final String label;
  final Color color;

  static TaskStatus fromApi(String value) => TaskStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => TaskStatus.pending,
      );
}

/// Estado del turno de la cuidadora.
enum ShiftStatus {
  checkedIn('checked_in', 'En turno', AppColors.statusOk, Icons.login_rounded),
  checkedOut(
      'checked_out', 'Fuera de turno', AppColors.textSecondary,
      Icons.logout_rounded);

  const ShiftStatus(this.apiValue, this.label, this.color, this.icon);

  final String apiValue;
  final String label;
  final Color color;
  final IconData icon;

  bool get isCheckedIn => this == ShiftStatus.checkedIn;

  /// Tipo de check-in a enviar según el estado actual: si está fuera, entra.
  String get nextCheckinType => isCheckedIn ? 'out' : 'in';

  static ShiftStatus fromApi(String value) => ShiftStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => ShiftStatus.checkedOut,
      );
}

/// Nivel de plan de la cuidadora (freemium).
enum PlanTier {
  free('free', 'Gratis'),
  premium('premium', 'Premium');

  const PlanTier(this.apiValue, this.label);

  final String apiValue;
  final String label;

  bool get isFree => this == PlanTier.free;
  bool get isPremium => this == PlanTier.premium;

  static PlanTier fromApi(String value) => PlanTier.values.firstWhere(
        (t) => t.apiValue == value,
        orElse: () => PlanTier.free,
      );
}

// ---------------------------------------------------------------------------
// Tarea de cuidado
// ---------------------------------------------------------------------------

/// Tarea del plan de cuidado (baño, medicación, caminata...).
class CareTask {
  const CareTask({
    required this.id,
    required this.title,
    this.description,
    this.due,
    this.status = TaskStatus.pending,
    this.category,
  });

  final String id;
  final String title;
  final String? description;
  final DateTime? due;
  final TaskStatus status;
  final String? category;

  String get timeLabel => due == null
      ? 'Sin hora'
      : '${due!.hour.toString().padLeft(2, '0')}:${due!.minute.toString().padLeft(2, '0')}';

  CareTask copyWith({TaskStatus? status}) => CareTask(
        id: id,
        title: title,
        description: description,
        due: due,
        status: status ?? this.status,
        category: category,
      );

  factory CareTask.fromJson(Map<String, dynamic> json) => CareTask(
        id: (json['id'] ?? json['task_id']).toString(),
        title: (json['title'] ?? '') as String,
        description: json['description'] as String?,
        due: json['due'] != null ? DateTime.parse(json['due'] as String) : null,
        status: TaskStatus.fromApi((json['status'] ?? 'pending') as String),
        category: json['category'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (description != null) 'description': description,
        if (due != null) 'due': due!.toIso8601String(),
        'status': status.apiValue,
        if (category != null) 'category': category,
      };
}

/// Solicitud de creación de una tarea.
class NewCareTask {
  const NewCareTask({
    required this.title,
    this.description,
    this.due,
    this.category,
  });

  final String title;
  final String? description;
  final DateTime? due;
  final String? category;

  Map<String, dynamic> toJson() => {
        'title': title,
        if (description != null && description!.isNotEmpty)
          'description': description,
        if (due != null) 'due': due!.toIso8601String(),
        if (category != null && category!.isNotEmpty) 'category': category,
      };
}

// ---------------------------------------------------------------------------
// Resumen del día
// ---------------------------------------------------------------------------

/// Resumen del turno de la cuidadora para "Hoy".
class CaregiverToday {
  const CaregiverToday({
    required this.patientId,
    required this.patientName,
    required this.shiftStatus,
    this.wellbeingStatus = WellbeingStatus.ok,
    this.pendingTasks = const [],
    this.observationsCount = 0,
    this.alertsCount = 0,
    this.adherencePct,
  });

  final String patientId;
  final String patientName;
  final ShiftStatus shiftStatus;
  final WellbeingStatus wellbeingStatus;
  final List<CareTask> pendingTasks;
  final int observationsCount;
  final int alertsCount;
  final double? adherencePct;

  factory CaregiverToday.fromJson(Map<String, dynamic> json) => CaregiverToday(
        patientId: (json['patient_id'] ?? '').toString(),
        patientName: (json['patient_name'] ?? '') as String,
        shiftStatus:
            ShiftStatus.fromApi((json['shift_status'] ?? 'checked_out') as String),
        wellbeingStatus:
            WellbeingStatus.fromApi((json['wellbeing_status'] ?? 'ok') as String),
        pendingTasks: ((json['pending_tasks'] ?? []) as List)
            .map((e) => CareTask.fromJson(e as Map<String, dynamic>))
            .toList(),
        observationsCount: (json['observations_count'] ?? 0) as int,
        alertsCount: (json['alerts_count'] ?? 0) as int,
        adherencePct: json['adherence_pct'] != null
            ? (json['adherence_pct'] as num).toDouble()
            : null,
      );
}

// ---------------------------------------------------------------------------
// Observación
// ---------------------------------------------------------------------------

/// Observación registrada por la cuidadora en la bitácora.
class Observation {
  const Observation({
    required this.id,
    required this.text,
    this.category,
    this.mediaUrl,
    required this.createdAt,
    required this.authorName,
  });

  final String id;
  final String text;
  final String? category;
  final String? mediaUrl;
  final DateTime createdAt;
  final String authorName;

  factory Observation.fromJson(Map<String, dynamic> json) => Observation(
        id: (json['id'] ?? json['observation_id']).toString(),
        text: (json['text'] ?? '') as String,
        category: json['category'] as String?,
        mediaUrl: json['media_url'] as String?,
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : DateTime.now(),
        authorName: (json['author_name'] ?? '') as String,
      );
}

// ---------------------------------------------------------------------------
// Nota de relevo
// ---------------------------------------------------------------------------

/// Nota de relevo (handover) entre turnos de cuidado.
class HandoverNote {
  const HandoverNote({
    required this.id,
    required this.text,
    required this.authorName,
    required this.createdAt,
  });

  final String id;
  final String text;
  final String authorName;
  final DateTime createdAt;

  factory HandoverNote.fromJson(Map<String, dynamic> json) => HandoverNote(
        id: (json['id'] ?? json['note_id']).toString(),
        text: (json['text'] ?? '') as String,
        authorName: (json['author_name'] ?? '') as String,
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : DateTime.now(),
      );
}

// ---------------------------------------------------------------------------
// Plan (freemium)
// ---------------------------------------------------------------------------

/// Plan freemium de la cuidadora.
class CaregiverPlan {
  const CaregiverPlan({
    required this.tier,
    this.features = const [],
    required this.limitsText,
  });

  final PlanTier tier;
  final List<String> features;
  final String limitsText;

  factory CaregiverPlan.fromJson(Map<String, dynamic> json) => CaregiverPlan(
        tier: PlanTier.fromApi((json['tier'] ?? 'free') as String),
        features: ((json['features'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        limitsText: (json['limits_text'] ?? json['limits'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'tier': tier.apiValue,
        'features': features,
        'limits_text': limitsText,
      };
}

// ---------------------------------------------------------------------------
// Perfil de la cuidadora
// ---------------------------------------------------------------------------

/// Perfil profesional de la cuidadora (marketplace).
class CaregiverProfile {
  const CaregiverProfile({
    this.headline = '',
    this.bio = '',
    this.yearsExperience = 0,
    this.specialties = const [],
    this.languages = const [],
    this.zones = const [],
    this.certifications = const [],
  });

  final String headline;
  final String bio;
  final int yearsExperience;
  final List<String> specialties;
  final List<String> languages;
  final List<String> zones;
  final List<String> certifications;

  CaregiverProfile copyWith({
    String? headline,
    String? bio,
    int? yearsExperience,
    List<String>? specialties,
    List<String>? languages,
    List<String>? zones,
    List<String>? certifications,
  }) =>
      CaregiverProfile(
        headline: headline ?? this.headline,
        bio: bio ?? this.bio,
        yearsExperience: yearsExperience ?? this.yearsExperience,
        specialties: specialties ?? this.specialties,
        languages: languages ?? this.languages,
        zones: zones ?? this.zones,
        certifications: certifications ?? this.certifications,
      );

  factory CaregiverProfile.fromJson(Map<String, dynamic> json) =>
      CaregiverProfile(
        headline: (json['headline'] ?? '') as String,
        bio: (json['bio'] ?? '') as String,
        yearsExperience: (json['years_experience'] ?? 0) as int,
        specialties: ((json['specialties'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        languages: ((json['languages'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        zones:
            ((json['zones'] ?? []) as List).map((e) => e.toString()).toList(),
        certifications: ((json['certifications'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'headline': headline,
        'bio': bio,
        'years_experience': yearsExperience,
        'specialties': specialties,
        'languages': languages,
        'zones': zones,
        'certifications': certifications,
      };
}

// ---------------------------------------------------------------------------
// Reporte de desempeño
// ---------------------------------------------------------------------------

/// Métricas de desempeño de la cuidadora para el periodo.
class CaregiverReport {
  const CaregiverReport({
    required this.period,
    this.tasksCompleted = 0,
    this.punctualityPct = 0,
    this.checkinsOnTime = 0,
    this.observationsLogged = 0,
    this.weeklyTasks = const [],
  });

  final String period;
  final int tasksCompleted;
  final double punctualityPct;
  final int checkinsOnTime;
  final int observationsLogged;

  /// Serie semanal de tareas completadas (para la gráfica).
  final List<ReportPoint> weeklyTasks;

  factory CaregiverReport.fromJson(Map<String, dynamic> json) => CaregiverReport(
        period: (json['period'] ?? '') as String,
        tasksCompleted: (json['tasks_completed'] ?? 0) as int,
        punctualityPct: (json['punctuality_pct'] ?? 0) is num
            ? (json['punctuality_pct'] as num).toDouble()
            : 0,
        checkinsOnTime: (json['checkins_on_time'] ?? 0) as int,
        observationsLogged: (json['observations_logged'] ?? 0) as int,
        weeklyTasks: ((json['weekly_tasks'] ?? []) as List)
            .map((e) => ReportPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'period': period,
        'tasks_completed': tasksCompleted,
        'punctuality_pct': punctualityPct,
        'checkins_on_time': checkinsOnTime,
        'observations_logged': observationsLogged,
        'weekly_tasks': weeklyTasks.map((e) => e.toJson()).toList(),
      };
}

/// Un punto de la serie semanal del reporte.
class ReportPoint {
  const ReportPoint({required this.label, required this.value});

  final String label;
  final double value;

  factory ReportPoint.fromJson(Map<String, dynamic> json) => ReportPoint(
        label: (json['label'] ?? '') as String,
        value: (json['value'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'label': label, 'value': value};
}

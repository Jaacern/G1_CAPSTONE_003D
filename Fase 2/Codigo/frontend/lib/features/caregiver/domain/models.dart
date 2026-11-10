import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Estado de una tarea de cuidado (alineado con la API).
///
/// `tasks.py` acepta `done` o `completed` al escribir, pero al leer devuelve
/// siempre `done`; [cancelled] existe en la tabla y en el estado que se puede
/// enviar, así que la pantalla también tiene que saber mostrarlo.
enum TaskStatus {
  pending('pending', 'Pendiente', AppColors.textSecondary),
  inProgress('in_progress', 'En curso', AppColors.statusWarning),
  done('done', 'Completada', AppColors.statusOk),
  cancelled(
      'cancelled', 'Cancelada', AppColors.textFaint, Icons.cancel_outlined);

  const TaskStatus(this.apiValue, this.label, this.color,
      [this.icon = Icons.circle]);

  final String apiValue;
  final String label;
  final Color color;

  /// Icono del menú de estados; los tres primeros comparten círculo.
  final IconData icon;

  static TaskStatus fromApi(String value) => TaskStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => TaskStatus.pending,
      );
}

/// Estado del turno de la cuidadora.
enum ShiftStatus {
  checkedIn('checked_in', 'En turno', AppColors.statusOk, Icons.login_rounded),
  checkedOut('checked_out', 'Fuera de turno', AppColors.textSecondary,
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
// Categorías del plan de cuidado
// ---------------------------------------------------------------------------

/// Una categoría: [apiValue] es el código que guarda la API y [label] la
/// etiqueta que se muestra en pantalla.
class CareCategory {
  const CareCategory(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

/// Etiquetas en español de los códigos de categoría.
///
/// `logbook.py` y `tasks.py` aceptan código o etiqueta al escribir, pero al
/// leer devuelven siempre el código de base ('hygiene', 'food'...), así que la
/// traducción vive acá y no en cada tarjeta.
const _categoryLabels = <String, String>{
  'hygiene': 'Higiene',
  'medication': 'Medicación',
  'food': 'Alimentación',
  'activity': 'Actividad física',
  'company': 'Compañía',
  'sleep': 'Sueño',
  'mood': 'Ánimo',
  'mobility': 'Movilidad',
  'pain': 'Dolor',
  'visit': 'Visita',
  'other': 'Otro',
};

/// Categorías que ofrece el alta de tarea (tasks.py).
const taskCategories = <String>[
  'hygiene',
  'medication',
  'food',
  'activity',
  'company',
  'other',
];

/// Categorías que ofrece el alta de observación (logbook.py).
const observationCategories = <String>[
  'food',
  'mood',
  'sleep',
  'mobility',
  'hygiene',
  'other',
];

/// Etiqueta de una categoría tal como viene guardada.
///
/// Por código ('food' -> 'Alimentación') y también por etiqueta, que es como
/// la deja el modo demo. Un valor que no está en el catálogo se devuelve tal
/// cual: mostrar 'otras' escrito por alguien es mejor que mostrar nada.
String categoryLabel(String? guardada) {
  if (guardada == null || guardada.isEmpty) return '';
  final porCodigo = _categoryLabels[guardada];
  if (porCodigo != null) return porCodigo;
  // El modo demo guarda la etiqueta ya traducida: coincide y se devuelve tal
  // cual, sin pasar por el código.
  for (final etiqueta in _categoryLabels.values) {
    if (etiqueta == guardada) return etiqueta;
  }
  return guardada.replaceAll('_', ' ');
}

/// Código que hay que enviar o comparar para una categoría ya guardada.
///
/// Sirve para precargar un formulario: la API contesta el código y el demo
/// guarda la etiqueta, y las dos formas tienen que caer en la misma opción del
/// desplegable. Un valor fuera del catálogo devuelve null en vez de inventar
/// una categoría.
String? categoryCode(String? guardada) {
  if (guardada == null || guardada.isEmpty) return null;
  if (_categoryLabels.containsKey(guardada)) return guardada;
  for (final entry in _categoryLabels.entries) {
    if (entry.value == guardada) return entry.key;
  }
  return null;
}

/// Opciones del desplegable a partir de los códigos que admite el formulario.
List<CareCategory> categoryOptions(List<String> codigos) => [
      for (final code in codigos) CareCategory(code, categoryLabel(code)),
    ];

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

  /// Momento de la tarea ya traído a la zona de la cuidadora. Vale null
  /// cuando la tarea es "de todo el día".
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
        due: _debido(json['due']),
        status: TaskStatus.fromApi((json['status'] ?? 'pending') as String),
        category: json['category'] as String?,
      );
}

/// Hora prevista de una tarea, o null si es de todo el día.
///
/// `tasks.py` no manda la hora aparte: arma un instante UTC con `due_date` y
/// `due_time` y, cuando la tarea no tiene hora, pone la medianoche UTC. Por eso
/// el centinela se lee antes de convertir: a las 21:00 de Chile la medianoche
/// UTC del día siguiente se vería como una tarea con fecha corrida.
///
/// El mismo centinela tiene un costo real: una tarea pedida para las 21:00
/// locales viaja como 00:00 UTC y el backend la guarda como "sin hora".
DateTime? _debido(Object? crudo) {
  if (crudo == null) return null;
  final utc = DateTime.parse(crudo as String).toUtc();
  if (utc.hour == 0 && utc.minute == 0) return null;
  return utc.toLocal();
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
        // tasks.py le asigna UTC a cualquier instante escrito sin zona, así que
        // la hora local de la cuidadora tiene que viajar convertida y con su
        // designación de zona; si no, una tarea de las 08:00 queda a las 05:00.
        if (due != null) 'due': due!.toUtc().toIso8601String(),
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
        shiftStatus: ShiftStatus.fromApi(
            (json['shift_status'] ?? 'checked_out') as String),
        wellbeingStatus: WellbeingStatus.fromApi(
            (json['wellbeing_status'] ?? 'ok') as String),
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
            ? _enZonaLocal(json['created_at'] as String)
            : DateTime.now(),
        authorName: (json['author_name'] ?? '') as String,
      );
}

/// Instante de la API traído a la zona del teléfono.
///
/// Los routers de bitácora devuelven la columna con su zona ('...+00:00') y
/// DateTime.parse la deja en UTC; DateFormat formatea los campos tal como
/// están, así que una observación de las 15:10 aparecía firmada a las 18:10.
DateTime _enZonaLocal(String crudo) => DateTime.parse(crudo).toLocal();

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
            ? _enZonaLocal(json['created_at'] as String)
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
// Reporte de desempeño
// ---------------------------------------------------------------------------

/// Métricas de desempeño de la cuidadora para el periodo.
class CaregiverReport {
  const CaregiverReport({
    required this.period,
    this.days = 7,
    this.tasksCompleted = 0,
    this.punctualityPct = 0,
    this.checkinsOnTime = 0,
    this.observationsLogged = 0,
    this.weeklyTasks = const [],
  });

  final String period;

  /// Largo del periodo: 7, 30 o 90 días.
  final int days;
  final int tasksCompleted;
  final double punctualityPct;
  final int checkinsOnTime;
  final int observationsLogged;

  /// Serie de tareas completadas para la gráfica: por día hasta 30 días,
  /// por semana en 90.
  final List<ReportPoint> weeklyTasks;

  factory CaregiverReport.fromJson(Map<String, dynamic> json) =>
      CaregiverReport(
        period: (json['period'] ?? '') as String,
        days: (json['days'] ?? 7) as int,
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
        'days': days,
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

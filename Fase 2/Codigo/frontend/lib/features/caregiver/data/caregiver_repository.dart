import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../domain/models.dart';

abstract class CaregiverRepository {
  // Jornada
  Future<CaregiverToday> getToday();
  Future<ShiftStatus> checkin(String patientId,
      {required String type, double? lat, double? lng});

  // Freemium
  Future<CaregiverPlan> getPlan();
  Future<CaregiverPlan> upgradePlan();

  // Reportes / perfil
  Future<CaregiverReport> getReport();
  Future<CaregiverProfile> getProfile();
  Future<CaregiverProfile> updateProfile(CaregiverProfile profile);

  // Tareas
  Future<List<CareTask>> listTasks(String patientId);
  Future<CareTask> createTask(String patientId, NewCareTask data);
  Future<CareTask> setTaskStatus(String taskId, TaskStatus status);

  // Bitácora
  Future<List<Observation>> listObservations(String patientId);
  Future<Observation> createObservation(
    String patientId, {
    required String text,
    String? mediaUrl,
    String? category,
  });

  // Incidentes
  Future<void> createIncident(
    String patientId, {
    required String type,
    required String severity,
    required String description,
    String? mediaUrl,
  });

  // Relevo
  Future<List<HandoverNote>> listHandoverNotes(String patientId);
  Future<HandoverNote> createHandoverNote(
    String patientId, {
    required String text,
    String? toUserId,
  });
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class CaregiverRepositoryHttp implements CaregiverRepository {
  CaregiverRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<CaregiverToday> getToday() async {
    final data = await _api.get<Map<String, dynamic>>('/caregiver/today');
    return CaregiverToday.fromJson(data);
  }

  @override
  Future<ShiftStatus> checkin(String patientId,
      {required String type, double? lat, double? lng}) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/checkin',
      data: {
        'type': type,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      },
    );
    return ShiftStatus.fromApi(
        (res['shift_status'] ?? (type == 'in' ? 'checked_in' : 'checked_out'))
            as String);
  }

  @override
  Future<CaregiverPlan> getPlan() async {
    final data = await _api.get<Map<String, dynamic>>('/caregiver/plan');
    return CaregiverPlan.fromJson(data);
  }

  @override
  Future<CaregiverPlan> upgradePlan() async {
    final res =
        await _api.post<Map<String, dynamic>>('/caregiver/plan/upgrade');
    return CaregiverPlan.fromJson(res);
  }

  @override
  Future<CaregiverReport> getReport() async {
    final data = await _api.get<Map<String, dynamic>>('/caregiver/reports');
    return CaregiverReport.fromJson(data);
  }

  @override
  Future<CaregiverProfile> getProfile() async {
    final data = await _api.get<Map<String, dynamic>>('/caregiver/profile');
    return CaregiverProfile.fromJson(data);
  }

  @override
  Future<CaregiverProfile> updateProfile(CaregiverProfile profile) async {
    final res = await _api.put<Map<String, dynamic>>(
      '/caregiver/profile',
      data: profile.toJson(),
    );
    return CaregiverProfile.fromJson(res);
  }

  @override
  Future<List<CareTask>> listTasks(String patientId) async {
    final data =
        await _api.get<Map<String, dynamic>>('/patients/$patientId/tasks');
    return ((data['items'] ?? []) as List)
        .map((e) => CareTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<CareTask> createTask(String patientId, NewCareTask data) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/tasks',
      data: data.toJson(),
    );
    return CareTask.fromJson(res);
  }

  @override
  Future<CareTask> setTaskStatus(String taskId, TaskStatus status) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/tasks/$taskId/status',
      data: {'status': status.apiValue},
    );
    return CareTask.fromJson(res);
  }

  @override
  Future<List<Observation>> listObservations(String patientId) async {
    final data = await _api
        .get<Map<String, dynamic>>('/patients/$patientId/observations');
    return ((data['items'] ?? []) as List)
        .map((e) => Observation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Observation> createObservation(
    String patientId, {
    required String text,
    String? mediaUrl,
    String? category,
  }) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/observations',
      data: {
        'text': text,
        if (mediaUrl != null) 'media_url': mediaUrl,
        if (category != null) 'category': category,
      },
    );
    return Observation.fromJson(res);
  }

  @override
  Future<void> createIncident(
    String patientId, {
    required String type,
    required String severity,
    required String description,
    String? mediaUrl,
  }) =>
      _api.post<void>(
        '/patients/$patientId/incidents',
        data: {
          'type': type,
          'severity': severity,
          'description': description,
          if (mediaUrl != null) 'media_url': mediaUrl,
        },
      );

  @override
  Future<List<HandoverNote>> listHandoverNotes(String patientId) async {
    final data = await _api
        .get<Map<String, dynamic>>('/patients/$patientId/handover-notes');
    return ((data['items'] ?? []) as List)
        .map((e) => HandoverNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<HandoverNote> createHandoverNote(
    String patientId, {
    required String text,
    String? toUserId,
  }) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/handover-notes',
      data: {
        'text': text,
        if (toUserId != null) 'to_user_id': toUserId,
      },
    );
    return HandoverNote.fromJson(res);
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class CaregiverRepositoryMock implements CaregiverRepository {
  CaregiverRepositoryMock() {
    _seed();
  }

  static const _patientId = 'p-demo';
  static const _patientName = 'Doña Rosa Martínez';

  final List<CareTask> _tasks = [];
  final List<Observation> _observations = [];
  final List<HandoverNote> _handovers = [];
  ShiftStatus _shift = ShiftStatus.checkedIn;
  CaregiverPlan _plan = const CaregiverPlan(
    tier: PlanTier.free,
    features: [
      'Hasta 1 paciente',
      'Bitácora y observaciones',
      'Reportes básicos',
    ],
    limitsText: 'Hasta 1 paciente / reportes básicos',
  );
  CaregiverProfile _profile = const CaregiverProfile(
    headline: 'Cuidadora de adultos mayores con vocación y experiencia',
    bio: 'Acompaño a personas mayores en su día a día con paciencia y cariño. '
        'Especial atención a la movilidad y la toma de medicación.',
    yearsExperience: 6,
    specialties: ['Movilidad reducida', 'Demencia leve', 'Post-operatorio'],
    languages: ['Español', 'Inglés básico'],
    zones: ['Providencia', 'Las Condes', 'Ñuñoa'],
    certifications: ['Primeros auxilios', 'Cuidado del adulto mayor (SENAMA)'],
  );

  DateTime _at(int h, int m) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, h, m);
  }

  void _seed() {
    _tasks.addAll([
      CareTask(
        id: 't-bano',
        title: 'Baño e higiene personal',
        description: 'Ayudar con la ducha y el cuidado de la piel.',
        due: _at(9, 0),
        status: TaskStatus.done,
        category: 'Higiene',
      ),
      CareTask(
        id: 't-medicacion',
        title: 'Medicación del mediodía',
        description: 'Losartán 50 mg con el almuerzo.',
        due: _at(12, 0),
        status: TaskStatus.pending,
        category: 'Medicación',
      ),
      CareTask(
        id: 't-caminata',
        title: 'Caminata en el parque',
        description: 'Paseo corto de 20 minutos para movilidad.',
        due: _at(17, 0),
        status: TaskStatus.pending,
        category: 'Actividad física',
      ),
    ]);

    _observations.addAll([
      Observation(
        id: 'o-1',
        text: 'Desayunó bien y de buen ánimo. Presión estable.',
        category: 'Alimentación',
        createdAt: _at(9, 30),
        authorName: 'Elena Fuentes',
      ),
      Observation(
        id: 'o-2',
        text: 'Se notó algo cansada después de la siesta, sin molestias.',
        category: 'Ánimo',
        createdAt: _at(15, 10),
        authorName: 'Elena Fuentes',
      ),
    ]);

    _handovers.add(HandoverNote(
      id: 'h-1',
      text: 'Turno tranquilo. Falta la medicación del mediodía y la caminata '
          'de la tarde. Hidratar con frecuencia.',
      authorName: 'Carla Rivas',
      createdAt: _at(8, 0),
    ));
  }

  @override
  Future<CaregiverToday> getToday() async {
    await Future.delayed(const Duration(milliseconds: 300));
    final pending =
        _tasks.where((t) => t.status != TaskStatus.done).toList();
    return CaregiverToday(
      patientId: _patientId,
      patientName: _patientName,
      shiftStatus: _shift,
      wellbeingStatus: WellbeingStatus.ok,
      pendingTasks: pending,
      observationsCount: _observations.length,
      alertsCount: 0,
      adherencePct: 92,
    );
  }

  @override
  Future<ShiftStatus> checkin(String patientId,
      {required String type, double? lat, double? lng}) async {
    await Future.delayed(const Duration(milliseconds: 350));
    _shift = type == 'in' ? ShiftStatus.checkedIn : ShiftStatus.checkedOut;
    return _shift;
  }

  @override
  Future<CaregiverPlan> getPlan() async {
    await Future.delayed(const Duration(milliseconds: 250));
    return _plan;
  }

  @override
  Future<CaregiverPlan> upgradePlan() async {
    await Future.delayed(const Duration(milliseconds: 600));
    _plan = const CaregiverPlan(
      tier: PlanTier.premium,
      features: [
        'Pacientes ilimitados',
        'Reportes avanzados con tendencias',
        'Perfil destacado en el marketplace',
        'Soporte prioritario',
      ],
      limitsText: 'Sin límites',
    );
    return _plan;
  }

  @override
  Future<CaregiverReport> getReport() async {
    await Future.delayed(const Duration(milliseconds: 350));
    return const CaregiverReport(
      period: 'Últimos 7 días',
      tasksCompleted: 34,
      punctualityPct: 92,
      checkinsOnTime: 6,
      observationsLogged: 18,
      weeklyTasks: [
        ReportPoint(label: 'Lun', value: 5),
        ReportPoint(label: 'Mar', value: 6),
        ReportPoint(label: 'Mié', value: 4),
        ReportPoint(label: 'Jue', value: 5),
        ReportPoint(label: 'Vie', value: 6),
        ReportPoint(label: 'Sáb', value: 4),
        ReportPoint(label: 'Dom', value: 4),
      ],
    );
  }

  @override
  Future<CaregiverProfile> getProfile() async {
    await Future.delayed(const Duration(milliseconds: 250));
    return _profile;
  }

  @override
  Future<CaregiverProfile> updateProfile(CaregiverProfile profile) async {
    await Future.delayed(const Duration(milliseconds: 400));
    _profile = profile;
    return _profile;
  }

  @override
  Future<List<CareTask>> listTasks(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return List.of(_tasks);
  }

  @override
  Future<CareTask> createTask(String patientId, NewCareTask data) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final task = CareTask(
      id: 't-${DateTime.now().millisecondsSinceEpoch}',
      title: data.title,
      description: data.description,
      due: data.due,
      status: TaskStatus.pending,
      category: data.category,
    );
    _tasks.add(task);
    return task;
  }

  @override
  Future<CareTask> setTaskStatus(String taskId, TaskStatus status) async {
    await Future.delayed(const Duration(milliseconds: 250));
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i < 0) {
      throw ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'La tarea solicitada no existe.',
      );
    }
    final updated = _tasks[i].copyWith(status: status);
    _tasks[i] = updated;
    return updated;
  }

  @override
  Future<List<Observation>> listObservations(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final list = List.of(_observations)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<Observation> createObservation(
    String patientId, {
    required String text,
    String? mediaUrl,
    String? category,
  }) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final obs = Observation(
      id: 'o-${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      category: category,
      mediaUrl: mediaUrl,
      createdAt: DateTime.now(),
      authorName: 'Elena Fuentes',
    );
    _observations.add(obs);
    return obs;
  }

  @override
  Future<void> createIncident(
    String patientId, {
    required String type,
    required String severity,
    required String description,
    String? mediaUrl,
  }) async {
    await Future.delayed(const Duration(milliseconds: 400));
    // El incidente registrado alimenta también la bitácora como observación.
    _observations.add(Observation(
      id: 'inc-${DateTime.now().millisecondsSinceEpoch}',
      text: 'Incidente ($severity): $description',
      category: 'Incidente · $type',
      mediaUrl: mediaUrl,
      createdAt: DateTime.now(),
      authorName: 'Elena Fuentes',
    ));
  }

  @override
  Future<List<HandoverNote>> listHandoverNotes(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final list = List.of(_handovers)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<HandoverNote> createHandoverNote(
    String patientId, {
    required String text,
    String? toUserId,
  }) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final note = HandoverNote(
      id: 'h-${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      authorName: 'Elena Fuentes',
      createdAt: DateTime.now(),
    );
    _handovers.add(note);
    return note;
  }
}

final caregiverRepositoryProvider = Provider<CaregiverRepository>((ref) {
  if (AppConfig.useMocks) return CaregiverRepositoryMock();
  return CaregiverRepositoryHttp(ref.watch(apiClientProvider));
});

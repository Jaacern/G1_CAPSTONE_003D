import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

abstract class AssistantRepository {
  /// Conversaciones del asistente para un paciente.
  Future<List<AssistantConversation>> listConversations(String patientId);

  /// Mensajes de una conversación concreta.
  Future<List<AssistantMessage>> fetchMessages(String conversationId);

  /// Envía una pregunta al asistente sobre el expediente. Si [conversationId]
  /// es null, se crea una conversación nueva. Devuelve la respuesta y el id de
  /// la conversación.
  Future<AssistantReply> ask(
    String patientId, {
    String? conversationId,
    required String text,
  });
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class AssistantRepositoryHttp implements AssistantRepository {
  AssistantRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<AssistantConversation>> listConversations(
      String patientId) async {
    final data = await _api.get<Map<String, dynamic>>(
        '/patients/$patientId/assistant/conversations');
    return ((data['items'] ?? []) as List)
        .map((e) => AssistantConversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<AssistantMessage>> fetchMessages(String conversationId) async {
    final data = await _api.get<Map<String, dynamic>>(
        '/assistant/conversations/$conversationId/messages');
    return ((data['items'] ?? []) as List)
        .map((e) => AssistantMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<AssistantReply> ask(
    String patientId, {
    String? conversationId,
    required String text,
  }) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/assistant/messages',
      data: {
        if (conversationId != null) 'conversation_id': conversationId,
        'text': text,
      },
    );
    return AssistantReply.fromJson(res);
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class AssistantRepositoryMock implements AssistantRepository {
  final Map<String, List<AssistantMessage>> _byConversation = {};
  final Map<String, List<AssistantConversation>> _byPatient = {};

  @override
  Future<List<AssistantConversation>> listConversations(
      String patientId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return List<AssistantConversation>.from(
        _byPatient[patientId] ?? const []);
  }

  @override
  Future<List<AssistantMessage>> fetchMessages(String conversationId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return List<AssistantMessage>.from(
        _byConversation[conversationId] ?? const []);
  }

  @override
  Future<AssistantReply> ask(
    String patientId, {
    String? conversationId,
    required String text,
  }) async {
    await Future.delayed(const Duration(milliseconds: 900));

    final convId =
        conversationId ?? 'conv-${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();

    // Guarda el mensaje del usuario.
    final userMsg = AssistantMessage(
      id: 'a-${now.millisecondsSinceEpoch}-u',
      role: AssistantRole.user,
      text: text,
      createdAt: now,
    );

    final answer = _answerFor(text);
    final assistantMsg = AssistantMessage(
      id: 'a-${now.millisecondsSinceEpoch}-a',
      role: AssistantRole.assistant,
      text: answer.text,
      createdAt: now.add(const Duration(seconds: 1)),
      citations: answer.citations,
    );

    _byConversation.putIfAbsent(convId, () => []);
    _byConversation[convId]!.addAll([userMsg, assistantMsg]);

    // Registra/actualiza la cabecera de la conversación del paciente.
    final list = _byPatient.putIfAbsent(patientId, () => []);
    final existingIdx = list.indexWhere((c) => c.id == convId);
    final header = AssistantConversation(
      id: convId,
      title: text.length > 40 ? '${text.substring(0, 40)}…' : text,
      updatedAt: now,
    );
    if (existingIdx >= 0) {
      list[existingIdx] = header;
    } else {
      list.insert(0, header);
    }

    return AssistantReply(conversationId: convId, message: assistantMsg);
  }

  /// Respuestas de demostración con el mismo comportamiento que el backend
  /// (routers/assistant.py + assistant_safety.py): solo datos registrados en
  /// el expediente de demo de Elena (seed del backend), con fecha, promedio
  /// y rango, sin calificar los valores ("normal", "estable", "buen
  /// camino") y derivando al médico tratante ante preguntas clínicas. Las
  /// etiquetas de las fuentes son las mismas que devuelve la API.
  ({String text, List<Citation> citations}) _answerFor(String question) {
    final q = question.toLowerCase();

    const paciente = Citation(label: 'Datos del paciente', reference: 'patients');
    const mediciones = Citation(label: 'Mediciones', reference: 'vital_readings');
    const medicamentos = Citation(label: 'Medicamentos', reference: 'medications');
    const dosis = Citation(label: 'Dosis', reference: 'scheduled_doses');
    const bitacora = Citation(label: 'Bitácora', reference: 'care_observations');
    const alertas = Citation(label: 'Alertas', reference: 'alerts');

    // Diagnóstico, interpretación o cambio de tratamiento: el backend no lo
    // responde. Entrega lo registrado y deriva.
    final pideCriterio = RegExp(
      r'(es normal|está bien|esta bien|es grave|qué tiene|que tiene|'
      r'diagn|subir|bajar|aumentar|reducir|suspender|duplicar|le doy|'
      r'puedo darle|receta)',
    ).hasMatch(q);
    if (pideCriterio) {
      return (
        text: 'No puedo interpretar los valores ni indicar cambios de '
            'tratamiento o dosis. Lo registrado en el expediente: '
            'condiciones registradas: diabetes tipo 2 e hipertensión. '
            'Medicamentos vigentes: Losartán 50 mg y Metformina 850 mg. '
            'Última presión arterial registrada: 138/85 mmHg el 03-11. '
            'Saturación de oxígeno de la semana: promedio 96.9 %, mínimo '
            '96.1 % y máximo 97.7 %.\n'
            'Para interpretar estos datos o decidir sobre tratamientos y '
            'dosis, consulta con el médico tratante.',
        citations: const [paciente, medicamentos, mediciones],
      );
    }

    if (q.contains('durm') || q.contains('sueñ') || q.contains('anoche')) {
      return (
        text: 'Sueño de la semana: 1 día con registro. El 02-11 se '
            'registraron 6.7 horas. En la bitácora del 02-11: "Despertó tres '
            'veces en la noche. Dice que le dolía la cadera."',
        citations: const [paciente, mediciones, bitacora],
      );
    }

    if (q.contains('medic') || q.contains('tomó') || q.contains('dosis') ||
        q.contains('olvid') || q.contains('adheren')) {
      return (
        text: 'Sí. En el último mes hubo 28 dosis que no se tomaron, de las '
            '135 programadas.\n'
            '6 omitidas a propósito (con motivo: malestar estomacal).\n'
            '12 no tomadas.\n'
            '10 sin registrar (pasó la hora y nadie anotó si se tomó).\n'
            'Por medicamento: Losartán 43 de 54 tomadas; Metformina 64 de 81 '
            'tomadas.',
        citations: const [paciente, medicamentos, dosis],
      );
    }

    if (q.contains('ritmo') || q.contains('corazón') || q.contains('cardí') ||
        q.contains('pulso') || q.contains('frecuencia')) {
      return (
        text: 'Frecuencia cardíaca de la semana: 45 mediciones, promedio '
            '67.3 bpm, mínimo 54.9 y máximo 78.7 bpm.\n'
            '02-11: promedio 68.2 bpm (rango 54.9-78.7, 24 mediciones).\n'
            '03-11: promedio 66.3 bpm (rango 55.3-76.6, 21 mediciones).',
        citations: const [paciente, mediciones],
      );
    }

    if (q.contains('presi') || q.contains('tensi')) {
      return (
        text: 'Presión arterial de la semana: 1 medición registrada, '
            '138/85 mmHg el 03-11.',
        citations: const [paciente, mediciones],
      );
    }

    if (q.contains('camin') || q.contains('activ') || q.contains('paso')) {
      return (
        text: 'Pasos de la semana: 1 día con registro, 1661 pasos el 02-11. '
            'En la bitácora del 03-11: "Caminó hasta el patio con el '
            'andador, sin apoyo adicional."',
        citations: const [paciente, mediciones, bitacora],
      );
    }

    if (q.contains('alert')) {
      return (
        text: 'Alertas activas ahora: Wearable sin sincronizar (03-11, '
            'info).\n'
            'En el último mes se registraron 9 alertas; las demás ya fueron '
            'vistas o resueltas, por ejemplo: Caída detectada en el baño '
            '(31-10, vista).',
        citations: const [paciente, alertas],
      );
    }

    return (
      text: 'Resumen de la semana con lo registrado en el expediente:\n'
          'Frecuencia cardíaca: promedio 67.3 bpm (mínimo 54.9, máximo '
          '78.7).\n'
          'Presión arterial: 138/85 mmHg el 03-11 (única medición).\n'
          'Saturación de oxígeno: promedio 96.9 % (mínimo 96.1, máximo '
          '97.7).\n'
          'Dosis: 8 tomadas de 20 programadas.\n'
          'Alertas activas ahora: Wearable sin sincronizar.\n'
          'Puedes preguntarme por el sueño, las dosis, el pulso o la '
          'bitácora de un día o período.',
      citations: const [paciente, mediciones, dosis, alertas],
    );
  }
}

final assistantRepositoryProvider = Provider<AssistantRepository>((ref) {
  if (AppConfig.useMocks) return AssistantRepositoryMock();
  return AssistantRepositoryHttp(ref.watch(apiClientProvider));
});

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

  ({String text, List<Citation> citations}) _answerFor(String question) {
    final q = question.toLowerCase();

    if (q.contains('durm') || q.contains('sueñ') || q.contains('anoche')) {
      return (
        text: 'Elena durmió alrededor de 7 h 20 min anoche, con un despertar '
            'breve hacia las 3:00 a. m. Su descanso profundo fue del 22 %, '
            'un poco mejor que el promedio de la semana. En general, una '
            'noche tranquila.',
        citations: const [
          Citation(label: 'Sueño', reference: 'Registro del wearable · anoche'),
        ],
      );
    }

    if (q.contains('medic') || q.contains('tomó') || q.contains('dosis') ||
        q.contains('adheren')) {
      return (
        text: 'Hoy Elena ha tomado 2 de 3 dosis programadas. Confirmó el '
            'Losartán de la mañana y la vitamina D; queda pendiente el '
            'Losartán de la noche (20:00). La adherencia de los últimos 7 '
            'días es del 94 %.',
        citations: const [
          Citation(label: 'Medicamentos', reference: 'Plan de hoy'),
          Citation(label: 'Adherencia', reference: 'Últimos 7 días'),
        ],
      );
    }

    if (q.contains('ritmo') || q.contains('corazón') || q.contains('cardí') ||
        q.contains('pulso') || q.contains('frecuencia')) {
      return (
        text: 'El último ritmo cardíaco registrado fue de 74 lpm, hace 18 '
            'minutos, dentro de su rango habitual (62–88 lpm). No se han '
            'detectado episodios fuera de rango en las últimas 24 horas.',
        citations: const [
          Citation(
              label: 'Ritmo cardíaco', reference: 'Última lectura · hace 18 min'),
        ],
      );
    }

    if (q.contains('camin') || q.contains('activ') || q.contains('paso')) {
      return (
        text: 'Elena lleva 2 340 pasos hoy y alrededor de 35 minutos de '
            'actividad ligera, principalmente durante su paseo de la mañana '
            'por el parque. Va en buen camino para su meta diaria.',
        citations: const [
          Citation(label: 'Actividad', reference: 'Registro de hoy'),
        ],
      );
    }

    return (
      text: 'Según el expediente de Elena, sus signos vitales de hoy están '
          'estables, la adherencia a medicamentos es del 94 % esta semana y '
          'no hay alertas activas. ¿Quieres que profundice en el sueño, los '
          'medicamentos o el ritmo cardíaco?',
      citations: const [
        Citation(label: 'Resumen del expediente', reference: 'Hoy'),
      ],
    );
  }
}

final assistantRepositoryProvider = Provider<AssistantRepository>((ref) {
  if (AppConfig.useMocks) return AssistantRepositoryMock();
  return AssistantRepositoryHttp(ref.watch(apiClientProvider));
});

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

abstract class ChatRepository {
  /// Historial de mensajes (más reciente primero o cronológico según backend).
  /// [before] permite paginar hacia atrás (id/timestamp del mensaje más antiguo
  /// ya cargado). [limit] limita la cantidad.
  Future<List<ChatMessage>> fetchMessages(
    String patientId, {
    String? before,
    int limit = 50,
  });

  /// Envía un mensaje (texto, nota de voz o foto).
  Future<ChatMessage> sendMessage(
    String patientId, {
    required MessageType type,
    String? text,
    String? mediaUrl,
  });

  /// Marca como leídos los mensajes del chat.
  Future<void> markRead(String patientId);

  /// Stream de mensajes nuevos del chat.
  ///
  /// El backend solo sabe de `GET /chat/messages`, así que esto es un sondeo
  /// periódico de ese endpoint, no una conexión en tiempo real. Se entrega
  /// como Stream para que la pantalla no tenga que cambiar nada.
  Stream<ChatMessage> connect(String patientId);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class ChatRepositoryHttp implements ChatRepository {
  ChatRepositoryHttp(this._api, {this.sondeoCada = _sondeoCadaPorDefecto});

  final ApiClient _api;

  /// Cada cuánto se pregunta al backend por mensajes nuevos. Es configurable
  /// solo para que la prueba no tenga que esperar los 5 s reales.
  @visibleForTesting
  final Duration sondeoCada;

  static const Duration _sondeoCadaPorDefecto = Duration(seconds: 5);

  @override
  Future<List<ChatMessage>> fetchMessages(
    String patientId, {
    String? before,
    int limit = 50,
  }) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/chat/messages',
      query: {
        if (before != null) 'before': before,
        'limit': limit,
      },
    );
    return ((data['items'] ?? []) as List)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ChatMessage> sendMessage(
    String patientId, {
    required MessageType type,
    String? text,
    String? mediaUrl,
  }) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/chat/messages',
      data: {
        'type': type.apiValue,
        if (text != null) 'text': text,
        if (mediaUrl != null) 'media_url': mediaUrl,
      },
    );
    return ChatMessage.fromJson(res);
  }

  @override
  Future<void> markRead(String patientId) =>
      _api.post<void>('/patients/$patientId/chat/read');

  @override
  Stream<ChatMessage> connect(String patientId) {
    // Antes esto abría un WebSocket a /ws/patients/{id}/chat. Ese endpoint no
    // existe en el backend (no hay ninguna ruta ws registrada), así que el
    // handshake respondía 404 y nunca llegaba un mensaje: el chat parecía en
    // vivo pero no se actualizaba hasta salir y volver a entrar.
    //
    // Se sondea el único endpoint que sí existe. `GET /chat/messages` entrega
    // del más nuevo al más viejo, por eso se recorre al revés: la conversación
    // se lee cronológica.
    late final StreamController<ChatMessage> controller;
    Timer? timer;
    final vistos = <String>{};

    Future<void> sondeo() async {
      try {
        final mensajes = await fetchMessages(patientId, limit: 50);
        if (controller.isClosed) return;
        for (final m in mensajes.reversed) {
          if (vistos.add(m.id)) controller.add(m);
        }
      } catch (_) {
        // Un fallo de red no corta el stream: el próximo sondeo reintenta. Si
        // lo propagáramos, StreamProvider quedaría en error y el chat no se
        // recuperaría aunque el backend volviera.
      }
    }

    controller = StreamController<ChatMessage>(
      onListen: () {
        sondeo();
        timer = Timer.periodic(sondeoCada, (_) => sondeo());
      },
      onCancel: () {
        timer?.cancel();
        controller.close();
      },
    );
    return controller.stream;
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class ChatRepositoryMock implements ChatRepository {
  final Map<String, List<ChatMessage>> _byPatient = {};

  List<ChatMessage> _seed(String patientId) {
    final now = DateTime.now();
    return [
      ChatMessage(
        id: 'm-1',
        patientId: patientId,
        senderId: 'u-carmen',
        senderName: 'Carmen (cuidadora)',
        senderRole: 'caregiver',
        type: MessageType.text,
        text: 'Buenos días, familia. Ya llegué con Elena. 😊',
        createdAt: now.subtract(const Duration(hours: 3, minutes: 12)),
        readBy: const ['u-carmen'],
      ),
      ChatMessage(
        id: 'm-2',
        patientId: patientId,
        senderId: 'u-carmen',
        senderName: 'Carmen (cuidadora)',
        senderRole: 'caregiver',
        type: MessageType.text,
        text: 'Elena desayunó bien: avena, fruta y su café descafeinado.',
        createdAt: now.subtract(const Duration(hours: 3, minutes: 5)),
        readBy: const ['u-carmen'],
      ),
      ChatMessage(
        id: 'm-3',
        patientId: patientId,
        senderId: 'u-maria',
        senderName: 'María (familia)',
        senderRole: 'family',
        type: MessageType.text,
        text: '¡Qué bueno! Gracias por avisar, Carmen.',
        createdAt: now.subtract(const Duration(hours: 2, minutes: 58)),
        readBy: const ['u-maria', 'u-carmen'],
      ),
      ChatMessage(
        id: 'm-4',
        patientId: patientId,
        senderId: 'u-carmen',
        senderName: 'Carmen (cuidadora)',
        senderRole: 'caregiver',
        type: MessageType.voice,
        text: null,
        mediaUrl: 'https://mock.agecare.app/audio/nota-elena.m4a',
        createdAt: now.subtract(const Duration(hours: 2, minutes: 40)),
        readBy: const ['u-carmen'],
      ),
      ChatMessage(
        id: 'm-5',
        patientId: patientId,
        senderId: 'u-carmen',
        senderName: 'Carmen (cuidadora)',
        senderRole: 'caregiver',
        type: MessageType.text,
        text: 'Salimos a caminar un rato al parque. Todo tranquilo.',
        createdAt: now.subtract(const Duration(hours: 1, minutes: 30)),
        readBy: const ['u-carmen'],
      ),
    ];
  }

  List<ChatMessage> _list(String patientId) =>
      _byPatient.putIfAbsent(patientId, () => _seed(patientId));

  @override
  Future<List<ChatMessage>> fetchMessages(
    String patientId, {
    String? before,
    int limit = 50,
  }) async {
    await Future.delayed(const Duration(milliseconds: 350));
    return List<ChatMessage>.from(_list(patientId));
  }

  @override
  Future<ChatMessage> sendMessage(
    String patientId, {
    required MessageType type,
    String? text,
    String? mediaUrl,
  }) async {
    await Future.delayed(const Duration(milliseconds: 250));
    final msg = ChatMessage(
      id: 'm-${DateTime.now().millisecondsSinceEpoch}',
      patientId: patientId,
      senderId: 'u-me',
      senderName: 'Tú',
      senderRole: 'family',
      type: type,
      text: text,
      mediaUrl: mediaUrl,
      createdAt: DateTime.now(),
      readBy: const ['u-me'],
    );
    _list(patientId).add(msg);
    return msg;
  }

  @override
  Future<void> markRead(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 120));
  }

  @override
  Stream<ChatMessage> connect(String patientId) async* {
    // Simula la llegada de un par de mensajes de la cuidadora en tiempo real.
    await Future.delayed(const Duration(seconds: 3));
    yield ChatMessage(
      id: 'm-live-1-${DateTime.now().millisecondsSinceEpoch}',
      patientId: patientId,
      senderId: 'u-carmen',
      senderName: 'Carmen (cuidadora)',
      senderRole: 'caregiver',
      type: MessageType.text,
      text: 'Elena ya tomó su medicamento de la mañana. 👍',
      createdAt: DateTime.now(),
      readBy: const ['u-carmen'],
    );

    await Future.delayed(const Duration(seconds: 6));
    yield ChatMessage(
      id: 'm-live-2-${DateTime.now().millisecondsSinceEpoch}',
      patientId: patientId,
      senderId: 'u-carmen',
      senderName: 'Carmen (cuidadora)',
      senderRole: 'caregiver',
      type: MessageType.text,
      text: 'Está descansando ahora. Cualquier cosa les aviso.',
      createdAt: DateTime.now(),
      readBy: const ['u-carmen'],
    );
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  if (AppConfig.useMocks) return ChatRepositoryMock();
  return ChatRepositoryHttp(ref.watch(apiClientProvider));
});

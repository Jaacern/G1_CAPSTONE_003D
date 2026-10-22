import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';
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

  /// Suscripción en tiempo real a mensajes nuevos vía WebSocket.
  Stream<ChatMessage> connect(String patientId);
}

// ---------------------------------------------------------------------------
// HTTP + WebSocket
// ---------------------------------------------------------------------------
class ChatRepositoryHttp implements ChatRepository {
  ChatRepositoryHttp(this._api, this._tokens);

  final ApiClient _api;
  final TokenStorage _tokens;

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
  Stream<ChatMessage> connect(String patientId) async* {
    // El WebSocket no pasa por el interceptor de ApiClient, así que NO lleva
    // la cabecera Authorization automáticamente. Supuesto: el backend acepta
    // el access token como query param `?token=` en el handshake del WS
    // (patrón común cuando no se pueden fijar cabeceras del lado del cliente).
    final token = await _tokens.accessToken;

    // Construimos la URL ws/wss a partir de la base HTTP.
    final httpBase = AppConfig.apiBaseUrl + AppConfig.apiVersion;
    final wsBase = httpBase
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final wsUrl = '$wsBase/ws/patients/$patientId/chat'
        '${token != null ? '?token=$token' : ''}';

    final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    try {
      await for (final event in channel.stream) {
        final decoded = jsonDecode(event as String);
        if (decoded is Map<String, dynamic>) {
          // El backend puede envolver el evento: {type, data} o el mensaje plano.
          final payload = decoded['data'] is Map<String, dynamic>
              ? decoded['data'] as Map<String, dynamic>
              : decoded;
          if (payload['id'] != null) {
            yield ChatMessage.fromJson(payload);
          }
        }
      }
    } finally {
      await channel.sink.close();
    }
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
  return ChatRepositoryHttp(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
  );
});

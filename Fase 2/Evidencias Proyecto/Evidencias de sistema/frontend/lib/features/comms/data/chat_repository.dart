import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';
import '../domain/models.dart';

/// Abre el canal del chat. Es un parámetro para que las pruebas usen un
/// servidor local en vez de la red.
typedef AbrirSocket = WebSocketChannel Function(Uri uri);

abstract class ChatRepository {
  /// Historial del chat, del mensaje más nuevo al más viejo: así lo devuelve
  /// `GET /chat/messages` y así lo espera la pantalla al pagar hacia arriba.
  ///
  /// [before] paginaba hacia atrás con la FECHA del mensaje más antiguo ya
  /// cargado (el backend la declara `datetime | None`, no un id: mandarle un
  /// id devolvería 422). [limit] es el tamaño de página, entre 1 y 200.
  Future<List<ChatMessage>> fetchMessages(
    String patientId, {
    DateTime? before,
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

  /// Stream de mensajes nuevos del chat (RF-54).
  ///
  /// Entrega el historial reciente y después cada mensaje nuevo. Usa el
  /// WebSocket del backend (`/patients/{id}/chat/ws`) y, mientras no esté
  /// conectado, sondea `GET /chat/messages`. Es la misma red de seguridad en
  /// los dos sentidos: si el socket cae o el servidor no lo acepta, el chat
  /// sigue funcionando por sondeo y el socket se reintenta solo.
  Stream<ChatMessage> connect(String patientId);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class ChatRepositoryHttp implements ChatRepository {
  /// Sin [tokens] ni [abrirSocket] el chat funciona solo por sondeo (así lo
  /// usan las pruebas del sondeo). En la app, [chatRepositoryProvider] pasa
  /// los tokens y se usa el WebSocket.
  ChatRepositoryHttp(
    this._api, {
    this.sondeoCada = _sondeoCadaPorDefecto,
    this.sondeoConSocket = _sondeoConSocketPorDefecto,
    this.pingCada = _pingCadaPorDefecto,
    this.esperaMinimaReintento = _esperaMinimaPorDefecto,
    TokenStorage? tokens,
    AbrirSocket? abrirSocket,
  })  : _tokens = tokens,
        _abrirSocket =
            abrirSocket ?? (tokens == null ? null : WebSocketChannel.connect);

  final ApiClient _api;
  final TokenStorage? _tokens;
  final AbrirSocket? _abrirSocket;

  /// Cada cuánto se pregunta al backend por mensajes nuevos mientras NO hay
  /// socket. Es configurable solo para que la prueba no espere los 5 s reales.
  @visibleForTesting
  final Duration sondeoCada;

  /// Con el socket conectado el sondeo baja a una pasada ocasional. No sobra:
  /// cubre un aviso que se perdió mientras el socket se reconectaba, y de paso
  /// la llamada HTTP renueva el token de acceso, que el socket no puede.
  @visibleForTesting
  final Duration sondeoConSocket;

  /// Latido para que ni el túnel ni el servidor den por muerta una conexión
  /// callada. El backend responde "pong".
  @visibleForTesting
  final Duration pingCada;

  /// Espera antes del primer reintento del socket; se duplica hasta un tope.
  @visibleForTesting
  final Duration esperaMinimaReintento;

  static const Duration _sondeoCadaPorDefecto = Duration(seconds: 5);
  static const Duration _sondeoConSocketPorDefecto = Duration(seconds: 30);
  static const Duration _pingCadaPorDefecto = Duration(seconds: 25);
  static const Duration _esperaMinimaPorDefecto = Duration(seconds: 5);
  static const Duration _esperaMaximaReintento = Duration(seconds: 60);

  /// ws(s)://host/api/v1/patients/{id}/chat/ws?token=...
  ///
  /// El token va en la URL porque el WebSocket del navegador no admite
  /// cabeceras en el saludo inicial. Es el de acceso, que dura 30 minutos.
  @visibleForTesting
  static Uri uriSocket(String baseUrl, String patientId, String token) {
    final base = Uri.parse(baseUrl);
    final raiz = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '$raiz${AppConfig.apiVersion}/patients/$patientId/chat/ws',
      queryParameters: {'token': token},
    );
  }

  @override
  Future<List<ChatMessage>> fetchMessages(
    String patientId, {
    DateTime? before,
    int limit = 50,
  }) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/chat/messages',
      query: {
        // Se manda en UTC e ISO-8601: es el formato que FastAPI parsea como
        // datetime. Una fecha local con espacio o guiones de más daría 422.
        if (before != null) 'before': before.toUtc().toIso8601String(),
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
    // Dos fuentes que se complementan:
    //  - el WebSocket, que entrega cada mensaje al instante (RF-54);
    //  - el sondeo de `GET /chat/messages`, que trae el historial al abrir, y
    //    que sigue a un ritmo lento con el socket arriba y a uno rápido
    //    cuando el socket no está.
    // Los dos pasan por `emitir`, que descarta lo ya visto por id: un mensaje
    // que llega por socket y otra vez por sondeo se muestra una sola vez.
    late final StreamController<ChatMessage> controller;
    Timer? timerSondeo;
    Timer? timerPing;
    Timer? timerReintento;
    WebSocketChannel? canal;
    StreamSubscription<dynamic>? subCanal;
    var conectado = false;
    var cerrado = false;
    var intentos = 0;
    final vistos = <String>{};

    void emitir(ChatMessage m) {
      if (!controller.isClosed && vistos.add(m.id)) controller.add(m);
    }

    // `GET /chat/messages` entrega del más nuevo al más viejo, por eso se
    // recorre al revés: la conversación se lee cronológica.
    Future<void> sondeo() async {
      try {
        final mensajes = await fetchMessages(patientId, limit: 50);
        if (controller.isClosed) return;
        mensajes.reversed.forEach(emitir);
      } catch (_) {
        // Un fallo de red no corta el stream: el próximo sondeo reintenta. Si
        // lo propagáramos, StreamProvider quedaría en error y el chat no se
        // recuperaría aunque el backend volviera.
      }
    }

    void armarSondeo() {
      timerSondeo?.cancel();
      timerSondeo = Timer.periodic(
          conectado ? sondeoConSocket : sondeoCada, (_) => sondeo());
    }

    late final Future<void> Function() abrir;

    void caer() {
      if (cerrado || (timerReintento?.isActive ?? false)) return;
      conectado = false;
      timerPing?.cancel();
      subCanal?.cancel();
      try {
        canal?.sink.close();
      } catch (_) {}
      armarSondeo(); // sin socket vuelve el ritmo rápido
      // Espera exponencial con tope: 5 s, 10 s, 20 s, 40 s, 60 s...
      final factor = math.pow(2, math.min(intentos, 4)).toInt();
      final espera = esperaMinimaReintento * factor;
      intentos++;
      timerReintento = Timer(
        espera > _esperaMaximaReintento ? _esperaMaximaReintento : espera,
        abrir,
      );
    }

    abrir = () async {
      final abrirSocket = _abrirSocket;
      if (cerrado || abrirSocket == null) return;
      try {
        final token = await _tokens?.accessToken;
        if (cerrado) return;
        if (token == null) {
          caer();
          return;
        }
        final c = abrirSocket(uriSocket(AppConfig.apiBaseUrl, patientId, token));
        canal = c;
        await c.ready; // lanza si el servidor rechaza el saludo
        if (cerrado) {
          await c.sink.close();
          return;
        }
        conectado = true;
        intentos = 0;
        armarSondeo();
        // Lo que llegó mientras no había socket.
        unawaited(sondeo());
        timerPing = Timer.periodic(pingCada, (_) {
          try {
            c.sink.add('ping');
          } catch (_) {}
        });
        subCanal = c.stream.listen(
          (dato) {
            if (dato is! String || dato == 'pong') return;
            try {
              emitir(ChatMessage.fromJson(
                  jsonDecode(dato) as Map<String, dynamic>));
            } catch (_) {
              // Un mensaje que no se pudo leer no tumba la conexión; el
              // sondeo lo traerá por la otra vía.
            }
          },
          onError: (_) => caer(),
          onDone: caer,
          cancelOnError: true,
        );
      } catch (_) {
        caer();
      }
    };

    controller = StreamController<ChatMessage>(
      onListen: () {
        sondeo();
        armarSondeo();
        unawaited(abrir());
      },
      onCancel: () {
        cerrado = true;
        timerSondeo?.cancel();
        timerPing?.cancel();
        timerReintento?.cancel();
        subCanal?.cancel();
        try {
          canal?.sink.close();
        } catch (_) {}
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
    DateTime? before,
    int limit = 50,
  }) async {
    await Future.delayed(const Duration(milliseconds: 350));
    // Mismo contrato que el backend: del más nuevo al más viejo, cortando en
    // la fecha de `before` y trayendo a lo más `limit`. Se ordena una copia
    // para no reacomodar el historial que el repositorio guarda por dentro.
    final todos = List<ChatMessage>.from(_list(patientId))
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return todos
        .where((m) => before == null || m.createdAt.isBefore(before))
        .take(limit)
        .toList();
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
    tokens: ref.watch(tokenStorageProvider),
  );
});

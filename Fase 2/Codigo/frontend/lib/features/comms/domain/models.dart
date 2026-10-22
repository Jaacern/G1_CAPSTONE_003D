/// Modelos del módulo de comunicación: chat humano (familiar-cuidadora) y
/// asistente IA sobre el expediente del paciente.
/// Alineados con la Especificación de Endpoints v1 (JSON snake_case, ISO8601).

/// Tipo de mensaje del chat.
enum MessageType {
  text('text'),
  voice('voice'),
  photo('photo'),
  system('system');

  const MessageType(this.apiValue);
  final String apiValue;

  static MessageType fromApi(String v) => MessageType.values.firstWhere(
        (t) => t.apiValue == v,
        orElse: () => MessageType.text,
      );
}

/// Mensaje del chat humano del equipo de cuidado.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.patientId,
    required this.senderId,
    required this.senderName,
    required this.senderRole,
    required this.type,
    this.text,
    this.mediaUrl,
    required this.createdAt,
    this.readBy,
  });

  final String id;
  final String patientId;
  final String senderId;
  final String senderName;

  /// Rol del emisor (etiqueta o valor tipo RoleType, p. ej. 'family',
  /// 'caregiver' o su etiqueta legible).
  final String senderRole;
  final MessageType type;
  final String? text;
  final String? mediaUrl;
  final DateTime createdAt;
  final List<String>? readBy;

  bool get isSystem => type == MessageType.system;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        patientId: (json['patient_id'] ?? '') as String,
        senderId: (json['sender_id'] ?? '') as String,
        senderName: (json['sender_name'] ?? '') as String,
        senderRole: (json['sender_role'] ?? '') as String,
        type: MessageType.fromApi((json['type'] ?? 'text') as String),
        text: json['text'] as String?,
        mediaUrl: json['media_url'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        readBy: json['read_by'] != null
            ? ((json['read_by'] as List).map((e) => e.toString()).toList())
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'patient_id': patientId,
        'sender_id': senderId,
        'sender_name': senderName,
        'sender_role': senderRole,
        'type': type.apiValue,
        if (text != null) 'text': text,
        if (mediaUrl != null) 'media_url': mediaUrl,
        'created_at': createdAt.toIso8601String(),
        if (readBy != null) 'read_by': readBy,
      };
}

/// Rol de un mensaje en la conversación con el asistente IA.
enum AssistantRole {
  user('user'),
  assistant('assistant');

  const AssistantRole(this.apiValue);
  final String apiValue;

  static AssistantRole fromApi(String v) => AssistantRole.values.firstWhere(
        (r) => r.apiValue == v,
        orElse: () => AssistantRole.assistant,
      );
}

/// Cita/referencia del asistente al expediente del paciente.
class Citation {
  const Citation({required this.label, this.reference, this.url});

  /// Texto legible de la fuente (p. ej. "Medicamentos", "Ritmo cardíaco").
  final String label;

  /// Identificador o descripción de la referencia dentro del expediente.
  final String? reference;

  /// Enlace opcional al recurso citado.
  final String? url;

  factory Citation.fromJson(Map<String, dynamic> json) => Citation(
        label: (json['label'] ?? json['title'] ?? 'Expediente').toString(),
        reference: (json['reference'] ?? json['ref']) as String?,
        url: json['url'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        if (reference != null) 'reference': reference,
        if (url != null) 'url': url,
      };
}

/// Mensaje de la conversación con el asistente IA.
class AssistantMessage {
  const AssistantMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.citations,
  });

  final String id;
  final AssistantRole role;
  final String text;
  final DateTime createdAt;
  final List<Citation>? citations;

  bool get isUser => role == AssistantRole.user;

  factory AssistantMessage.fromJson(Map<String, dynamic> json) =>
      AssistantMessage(
        id: json['id'] as String,
        role: AssistantRole.fromApi((json['role'] ?? 'assistant') as String),
        text: (json['text'] ?? '') as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        citations: json['citations'] != null
            ? ((json['citations'] as List)
                .map((e) => Citation.fromJson(e as Map<String, dynamic>))
                .toList())
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.apiValue,
        'text': text,
        'created_at': createdAt.toIso8601String(),
        if (citations != null)
          'citations': citations!.map((c) => c.toJson()).toList(),
      };
}

/// Cabecera de una conversación con el asistente IA.
class AssistantConversation {
  const AssistantConversation({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime updatedAt;

  factory AssistantConversation.fromJson(Map<String, dynamic> json) =>
      AssistantConversation(
        id: json['id'] as String,
        title: (json['title'] ?? 'Conversación') as String,
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updated_at': updatedAt.toIso8601String(),
      };
}

/// Respuesta del asistente a una pregunta: el mensaje del asistente y el id de
/// la conversación (nueva o existente).
class AssistantReply {
  const AssistantReply({required this.conversationId, required this.message});

  final String conversationId;
  final AssistantMessage message;

  factory AssistantReply.fromJson(Map<String, dynamic> json) => AssistantReply(
        conversationId: json['conversation_id'] as String,
        message:
            AssistantMessage.fromJson(json['message'] as Map<String, dynamic>),
      );
}

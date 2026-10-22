import 'package:flutter/material.dart';

/// Modelos del módulo Adulto Mayor (vista accesible): fotos familiares y
/// contenido de entretenimiento ("Para ti").

/// Foto compartida por la familia con el adulto mayor.
class FamilyPhoto {
  const FamilyPhoto({
    required this.id,
    required this.url,
    this.caption,
    required this.fromName,
    required this.createdAt,
    this.reactions,
  });

  final String id;
  final String url;

  /// Texto cariñoso que acompaña la foto (p. ej. "Tus nietos en la playa").
  final String? caption;

  /// Nombre de quien compartió la foto.
  final String fromName;

  final DateTime createdAt;

  /// Conteo de reacciones por tipo: {'love': 3, 'like': 1, 'smile': 2}.
  final Map<String, int>? reactions;

  int reactionCount(String reaction) => reactions?[reaction] ?? 0;

  factory FamilyPhoto.fromJson(Map<String, dynamic> json) => FamilyPhoto(
        id: json['id'] as String,
        url: (json['url'] ?? json['file_url'] ?? '') as String,
        caption: json['caption'] as String?,
        fromName: (json['from_name'] ?? 'Tu familia') as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        reactions: (json['reactions'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), (v as num).toInt()),
        ),
      );

  FamilyPhoto copyWith({Map<String, int>? reactions}) => FamilyPhoto(
        id: id,
        url: url,
        caption: caption,
        fromName: fromName,
        createdAt: createdAt,
        reactions: reactions ?? this.reactions,
      );
}

/// Tipo de tarjeta de contenido del feed de entretenimiento.
enum ContentType {
  news('news', 'Noticia', Icons.newspaper_rounded, Color(0xFF1F6F8B)),
  joke('joke', 'Chiste', Icons.sentiment_very_satisfied_rounded,
      Color(0xFFE8A13A)),
  memory('memory', 'Recuerdo', Icons.photo_album_rounded, Color(0xFF7FB685)),
  exercise('exercise', 'Ejercicio suave', Icons.self_improvement_rounded,
      Color(0xFF2E9E5B)),
  tip('tip', 'Consejo', Icons.lightbulb_rounded, Color(0xFF14505F));

  const ContentType(this.apiValue, this.label, this.icon, this.color);

  final String apiValue;
  final String label;
  final IconData icon;
  final Color color;

  static ContentType fromApi(String value) => ContentType.values.firstWhere(
        (t) => t.apiValue == value,
        orElse: () => ContentType.tip,
      );
}

/// Tarjeta de contenido del feed "Para ti".
class ContentItem {
  const ContentItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.imageUrl,
  });

  final String id;
  final ContentType type;
  final String title;
  final String body;
  final String? imageUrl;

  /// Texto para leer en voz alta (título + cuerpo).
  String get spokenText => '$title. $body';

  factory ContentItem.fromJson(Map<String, dynamic> json) => ContentItem(
        id: json['id'] as String,
        type: ContentType.fromApi((json['type'] ?? 'tip') as String),
        title: (json['title'] ?? '') as String,
        body: (json['body'] ?? '') as String,
        imageUrl: json['image_url'] as String?,
      );
}

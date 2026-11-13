import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../application/elder_providers.dart';

/// Una melodia guardada con el Director Musical.
class Melodia {
  const Melodia({
    required this.id,
    required this.title,
    required this.durationSeconds,
    required this.audioUrl,
    required this.createdAt,
  });

  final String id;
  final String title;
  final int durationSeconds;
  final String audioUrl;
  final DateTime createdAt;

  factory Melodia.fromJson(Map<String, dynamic> json) => Melodia(
        id: json['id'].toString(),
        title: (json['title'] ?? 'Melodía') as String,
        durationSeconds: (json['duration_seconds'] ?? 0) as int,
        audioUrl: (json['audio_url'] ?? '') as String,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  /// "1:05" a partir de los segundos.
  String get duracion {
    final m = durationSeconds ~/ 60;
    final s = (durationSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Melodias del adulto mayor, la mas reciente primero
/// (GET /patients/{id}/music, RF-65).
final melodiasProvider =
    FutureProvider.autoDispose<List<Melodia>>((ref) async {
  final patientId = ref.watch(elderPatientIdProvider);
  if (patientId == null) return const [];
  final res = await ref
      .watch(apiClientProvider)
      .get<Map<String, dynamic>>('/patients/$patientId/music');
  return ((res['items'] ?? []) as List)
      .map((e) => Melodia.fromJson(e as Map<String, dynamic>))
      .toList();
});

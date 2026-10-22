import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

/// Repositorio del módulo Adulto Mayor: fotos familiares, reacciones y feed
/// de contenido de entretenimiento.
abstract class ElderRepository {
  Future<List<FamilyPhoto>> listPhotos(String patientId);
  Future<FamilyPhoto> addPhoto(String patientId,
      {required String fileUrl, String? caption});
  Future<void> reactPhoto(String photoId, String reaction);
  Future<void> deletePhoto(String photoId);
  Future<List<ContentItem>> contentFeed({String? category});
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class ElderRepositoryHttp implements ElderRepository {
  ElderRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<FamilyPhoto>> listPhotos(String patientId) async {
    final data =
        await _api.get<Map<String, dynamic>>('/patients/$patientId/photos');
    return ((data['items'] ?? []) as List)
        .map((e) => FamilyPhoto.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<FamilyPhoto> addPhoto(String patientId,
      {required String fileUrl, String? caption}) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/photos',
      data: {
        'file_url': fileUrl,
        if (caption != null && caption.isNotEmpty) 'caption': caption,
      },
    );
    return FamilyPhoto.fromJson(res);
  }

  @override
  Future<void> reactPhoto(String photoId, String reaction) =>
      _api.post<void>('/photos/$photoId/reactions',
          data: {'reaction': reaction});

  @override
  Future<void> deletePhoto(String photoId) =>
      _api.delete<void>('/photos/$photoId');

  @override
  Future<List<ContentItem>> contentFeed({String? category}) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/content/feed',
      query: {if (category != null && category.isNotEmpty) 'category': category},
    );
    return ((data['items'] ?? []) as List)
        .map((e) => ContentItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class ElderRepositoryMock implements ElderRepository {
  ElderRepositoryMock() {
    _seed();
  }

  final List<FamilyPhoto> _photos = [];

  void _seed() {
    final now = DateTime.now();
    _photos.addAll([
      FamilyPhoto(
        id: 'ph-1',
        url: 'https://picsum.photos/seed/nietos/800/600',
        caption: 'Tus nietos en la playa',
        fromName: 'María',
        createdAt: now.subtract(const Duration(days: 1)),
        reactions: const {'love': 2, 'smile': 1},
      ),
      FamilyPhoto(
        id: 'ph-2',
        url: 'https://picsum.photos/seed/familia/800/600',
        caption: 'La comida del domingo, todos juntos',
        fromName: 'Carlos',
        createdAt: now.subtract(const Duration(days: 3)),
        reactions: const {'love': 1, 'like': 1},
      ),
      FamilyPhoto(
        id: 'ph-3',
        url: 'https://picsum.photos/seed/jardin/800/600',
        caption: 'Las flores de tu jardín este año',
        fromName: 'Lucía',
        createdAt: now.subtract(const Duration(days: 6)),
        reactions: const {'smile': 2},
      ),
    ]);
  }

  @override
  Future<List<FamilyPhoto>> listPhotos(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return List.of(_photos)..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<FamilyPhoto> addPhoto(String patientId,
      {required String fileUrl, String? caption}) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final photo = FamilyPhoto(
      id: 'ph-${DateTime.now().millisecondsSinceEpoch}',
      url: fileUrl,
      caption: caption,
      fromName: 'Tú',
      createdAt: DateTime.now(),
      reactions: const {},
    );
    _photos.insert(0, photo);
    return photo;
  }

  @override
  Future<void> reactPhoto(String photoId, String reaction) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final i = _photos.indexWhere((p) => p.id == photoId);
    if (i < 0) return;
    final current = Map<String, int>.from(_photos[i].reactions ?? const {});
    current[reaction] = (current[reaction] ?? 0) + 1;
    _photos[i] = _photos[i].copyWith(reactions: current);
  }

  @override
  Future<void> deletePhoto(String photoId) async {
    await Future.delayed(const Duration(milliseconds: 250));
    _photos.removeWhere((p) => p.id == photoId);
  }

  @override
  Future<List<ContentItem>> contentFeed({String? category}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final all = <ContentItem>[
      const ContentItem(
        id: 'c-joke',
        type: ContentType.joke,
        title: 'Una sonrisa para hoy',
        body: '¿Qué le dice un semáforo a otro? No me mires que me estoy '
            'cambiando.',
      ),
      const ContentItem(
        id: 'c-memory',
        type: ContentType.memory,
        title: 'Un recuerdo bonito',
        body: 'Hace tiempo, en las tardes de verano, las familias se sentaban '
            'en la puerta a conversar y a ver pasar la vida. ¿Lo recuerdas?',
        imageUrl: 'https://picsum.photos/seed/recuerdo/800/500',
      ),
      const ContentItem(
        id: 'c-exercise',
        type: ContentType.exercise,
        title: 'Ejercicio suave: hombros',
        body: 'Sentado y cómodo, sube los hombros despacio hacia las orejas, '
            'mantén dos segundos y baja. Repite cinco veces, sin prisa.',
      ),
      const ContentItem(
        id: 'c-tip',
        type: ContentType.tip,
        title: 'Consejo del día',
        body: 'Recuerda beber un vaso de agua ahora. Mantenerte hidratado te '
            'ayuda a sentirte con más energía.',
      ),
    ];
    if (category == null || category.isEmpty) return all;
    return all.where((c) => c.type.apiValue == category).toList();
  }
}

final elderRepositoryProvider = Provider<ElderRepository>((ref) {
  if (AppConfig.useMocks) return ElderRepositoryMock();
  return ElderRepositoryHttp(ref.watch(apiClientProvider));
});

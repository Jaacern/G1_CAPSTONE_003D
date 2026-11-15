import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/timeline_repository.dart';
import '../domain/timeline.dart';

/// Lo que la pantalla del historial necesita saber en cada momento.
class TimelineState {
  const TimelineState({
    this.items = const [],
    this.nextCursor,
    this.cargando = true,
    this.cargandoMas = false,
    this.error,
  });

  final List<TimelineEvent> items;
  final String? nextCursor;

  /// Primera página en camino.
  final bool cargando;

  /// Página siguiente en camino (al llegar al final del scroll).
  final bool cargandoMas;
  final Object? error;

  bool get hayMas => nextCursor != null;

  TimelineState copyWith({
    List<TimelineEvent>? items,
    String? Function()? nextCursor,
    bool? cargando,
    bool? cargandoMas,
    Object? Function()? error,
  }) =>
      TimelineState(
        items: items ?? this.items,
        nextCursor: nextCursor != null ? nextCursor() : this.nextCursor,
        cargando: cargando ?? this.cargando,
        cargandoMas: cargandoMas ?? this.cargandoMas,
        error: error != null ? error() : this.error,
      );
}

/// Paciente + filtro: cada combinación tiene su propia lista paginada.
typedef TimelineKey = ({String patientId, TimelineFilter filter});

/// Historial paginado. Pide la primera página al crearse y las siguientes
/// con [cargarMas], que llama la lista al acercarse al final del scroll.
class TimelineController
    extends AutoDisposeFamilyNotifier<TimelineState, TimelineKey> {
  static const tamanoPagina = 20;

  @override
  TimelineState build(TimelineKey arg) {
    Future.microtask(_primera);
    return const TimelineState();
  }

  TimelineRepository get _repo => ref.read(timelineRepositoryProvider);

  Future<void> _primera() async {
    try {
      final p = await _repo.page(arg.patientId,
          limit: tamanoPagina, kinds: arg.filter.kinds);
      state = TimelineState(
          items: p.items, nextCursor: p.nextCursor, cargando: false);
    } catch (e) {
      state = TimelineState(cargando: false, error: e);
    }
  }

  Future<void> recargar() async {
    state = const TimelineState();
    await _primera();
  }

  Future<void> cargarMas() async {
    if (state.cargando || state.cargandoMas || !state.hayMas) return;
    state = state.copyWith(cargandoMas: true, error: () => null);
    try {
      final p = await _repo.page(arg.patientId,
          cursor: state.nextCursor,
          limit: tamanoPagina,
          kinds: arg.filter.kinds);
      state = state.copyWith(
        items: [...state.items, ...p.items],
        nextCursor: () => p.nextCursor,
        cargandoMas: false,
      );
    } catch (e) {
      // Lo ya cargado se queda; solo se avisa que la página siguiente falló.
      state = state.copyWith(cargandoMas: false, error: () => e);
    }
  }
}

final timelineControllerProvider = NotifierProvider.autoDispose
    .family<TimelineController, TimelineState, TimelineKey>(
        TimelineController.new);

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Controla el modo de tema (claro / oscuro / sistema) y lo recuerda entre
/// sesiones. Persistencia ligera con flutter_secure_storage (ya es dependencia).
class ThemeController extends Notifier<ThemeMode> {
  static const _key = 'agecare_theme_mode';
  final _storage = const FlutterSecureStorage();

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system; // valor inicial hasta que cargue la preferencia
  }

  Future<void> _load() async {
    try {
      final v = await _storage.read(key: _key);
      if (v != null) state = _fromString(v);
    } catch (_) {
      // Si falla el storage, se mantiene el modo sistema.
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      await _storage.write(key: _key, value: mode.name);
    } catch (_) {/* no bloquear la UI por un fallo de persistencia */}
  }

  /// Alterna entre claro y oscuro (ignora "sistema" para el switch simple).
  Future<void> toggle() =>
      set(state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);

  ThemeMode _fromString(String v) => switch (v) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      };
}

final themeControllerProvider =
    NotifierProvider<ThemeController, ThemeMode>(ThemeController.new);

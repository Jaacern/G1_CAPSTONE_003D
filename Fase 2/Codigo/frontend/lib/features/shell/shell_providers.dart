import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Índice de la pestaña activa del [MainShell].
///
/// Permite que pantallas hijas (por ejemplo, el botón "Ver salud" del inicio)
/// cambien de pestaña sin usar rutas, ya que las pestañas viven dentro del
/// shell y no son rutas propias de go_router.
///
/// Índices del rol familiar: 0 Hoy · 1 Salud · 2 Comunicación · 3 Marketplace · 4 Más.
final shellTabIndexProvider = StateProvider<int>((ref) => 0);

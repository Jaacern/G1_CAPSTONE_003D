import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Id con que el backend conoce a este teléfono para el push.
///
/// Vive en su propio archivo y no depende de nada a propósito. Lo escribe el
/// registrador de push, que sigue a la sesión, y lo lee el cierre de sesión.
/// Si el cierre de sesión leyera directamente al registrador, los dos
/// proveedores dependerían uno del otro.
class PushDeviceId {
  String? value;
}

final pushDeviceIdProvider = Provider<PushDeviceId>((ref) => PushDeviceId());

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Un dato guardado en el dispositivo, con la fecha en que se guardo.
class Guardado {
  const Guardado(this.dato, this.fecha);

  /// El JSON tal como lo devolvio la API, ya decodificado.
  final Object dato;

  /// Cuando se guardo. Es lo que se le muestra a la persona: no "sin
  /// conexion" a secas, sino de cuando es lo que esta leyendo.
  final DateTime fecha;
}

/// Guarda en el dispositivo la ultima respuesta buena de la API (RF-80).
///
/// Va en el almacen cifrado y no en las preferencias normales porque lo que
/// se guarda son datos del expediente: signos vitales, remedios, alertas. En
/// un telefono que se comparte, se presta o se pierde, eso no puede quedar en
/// un archivo legible. Es el mismo almacen donde ya viven los tokens de la
/// sesion y el tema, de ahi el prefijo propio.
///
/// Nada de lo que pasa aqui puede romper una pantalla. El almacen falla mas
/// seguido de lo que parece (modo privado del navegador, datos del sitio
/// bloqueados, un Keystore que no responde), asi que cada lectura y cada
/// escritura va en su try. Si no se pudo guardar, la proxima vez simplemente
/// no habra nada guardado, que es el comportamiento de antes.
class AlmacenLocal {
  AlmacenLocal([AlmacenCifrado? almacen])
      : _almacen = almacen ?? const AlmacenCifradoReal();

  final AlmacenCifrado _almacen;

  /// Prefijo propio, para que [limpiarTodo] borre solo lo guardado por esto y
  /// no la sesion de la persona.
  static const prefijo = 'agecare_cache_';

  Future<void> guardar(String clave, Object dato) async {
    try {
      await _almacen.escribir(
        '$prefijo$clave',
        jsonEncode({
          'fecha': DateTime.now().toIso8601String(),
          'dato': dato,
        }),
      );
    } catch (_) {
      // No poder guardar no es motivo para fallar lo que la persona pidio.
    }
  }

  Future<Guardado?> leer(String clave) async {
    try {
      final crudo = await _almacen.leer('$prefijo$clave');
      if (crudo == null) return null;
      final m = jsonDecode(crudo) as Map<String, dynamic>;
      final fecha = DateTime.tryParse('${m['fecha']}');
      final dato = m['dato'];
      if (fecha == null || dato == null) return null;
      return Guardado(dato as Object, fecha);
    } catch (_) {
      // Guardado por una version anterior de la app, o almacen ilegible. Se
      // trata como si no hubiera nada, que es lo unico seguro: mostrar algo
      // a medio entender de un expediente es peor que no mostrar nada.
      return null;
    }
  }

  /// Borra todo lo guardado.
  ///
  /// Se llama al entrar y al salir de la sesion. Si en el mismo telefono
  /// entra otra persona del circulo, o la misma a otra cuenta, no puede
  /// quedar viendo el expediente que quedo guardado de antes.
  Future<void> limpiarTodo() async {
    try {
      final claves = await _almacen.claves();
      for (final clave in claves.where((k) => k.startsWith(prefijo))) {
        await _almacen.borrar(clave);
      }
    } catch (_) {
      // Ver arriba: el almacen puede no estar disponible.
    }
  }
}

/// Lo minimo que [AlmacenLocal] necesita de un almacen cifrado.
///
/// Existe para poder reemplazarlo en las pruebas: flutter_secure_storage no
/// tiene implementacion de plataforma dentro de flutter_test, asi que un
/// almacen de verdad ahi no escribe nada y no se podria comprobar que lo
/// guardado vuelve igual.
abstract class AlmacenCifrado {
  Future<void> escribir(String clave, String valor);
  Future<String?> leer(String clave);
  Future<void> borrar(String clave);
  Future<List<String>> claves();
}

/// El de verdad, el mismo que ya usa la app para los tokens y el tema.
class AlmacenCifradoReal implements AlmacenCifrado {
  const AlmacenCifradoReal();

  static const _storage = FlutterSecureStorage();

  @override
  Future<void> escribir(String clave, String valor) =>
      _storage.write(key: clave, value: valor);

  @override
  Future<String?> leer(String clave) => _storage.read(key: clave);

  @override
  Future<void> borrar(String clave) => _storage.delete(key: clave);

  @override
  Future<List<String>> claves() async => (await _storage.readAll()).keys.toList();
}

final almacenLocalProvider = Provider<AlmacenLocal>((ref) => AlmacenLocal());

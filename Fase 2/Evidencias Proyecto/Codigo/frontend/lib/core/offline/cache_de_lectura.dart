import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_client.dart';
import 'almacen_local.dart';
import 'estado_de_conexion.dart';

/// Lectura que sirve igual con y sin conexion (RF-80).
///
/// El repositorio envuelve su GET con esto y no cambia nada mas: si el
/// servidor contesta, se devuelve lo de ahora y queda guardado; si no se
/// puede llegar al servidor, se devuelve lo ultimo que se guardo.
///
/// Se guarda el JSON crudo y no el objeto ya armado. Asi el guardado no
/// depende de como se escriban los modelos, y volver a leerlos pasa por el
/// mismo fromJson que una respuesta de verdad, sin un segundo camino de
/// armado que se pueda desincronizar.
///
/// Solo cae al guardado cuando el problema es la conexion. Un 403 o un 404
/// son respuestas del servidor y significan algo: mostrar datos viejos ahi
/// seria taparle a la persona que ya no tiene acceso a ese expediente.
class CacheDeLectura {
  CacheDeLectura(AlmacenLocal almacen, ConexionController conexion)
      : _almacen = almacen,
        _conexion = conexion;

  /// Pasa la llamada al servidor tal cual, sin guardar ni leer nada.
  ///
  /// Para armar un repositorio fuera de la app, como en las pruebas de
  /// pantalla, que no estan probando el guardado y no tienen almacen.
  const CacheDeLectura.sinGuardar()
      : _almacen = null,
        _conexion = null;

  final AlmacenLocal? _almacen;
  final ConexionController? _conexion;

  Future<T> leer<T extends Object>(
    String clave,
    Future<T> Function() traer,
  ) async {
    final almacen = _almacen;
    final conexion = _conexion;
    if (almacen == null || conexion == null) return traer();

    try {
      final fresco = await traer();
      await almacen.guardar(clave, fresco);
      conexion.recuperada();
      return fresco;
    } on ApiException catch (e) {
      if (e.code != 'NETWORK_ERROR') rethrow;

      final guardado = await almacen.leer(clave);
      if (guardado == null) {
        // Nunca se abrio esta pantalla con conexion, asi que no hay nada que
        // mostrar. Se avisa que no hay conexion y se deja pasar el error,
        // que es lo que la pantalla ya sabe manejar.
        conexion.perdida();
        rethrow;
      }
      conexion.perdida(fechaDelDato: guardado.fecha);
      return guardado.dato as T;
    }
  }
}

final cacheDeLecturaProvider = Provider<CacheDeLectura>((ref) => CacheDeLectura(
      ref.watch(almacenLocalProvider),
      ref.read(conexionProvider.notifier),
    ));

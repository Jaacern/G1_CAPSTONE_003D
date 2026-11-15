import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Si la app esta logrando hablar con el servidor, y de cuando son los datos
/// que esta mostrando mientras no lo logra.
class EstadoDeConexion {
  const EstadoDeConexion({this.sinConexion = false, this.datoMasViejo});

  final bool sinConexion;

  /// Fecha del dato guardado mas antiguo que se sirvio sin conexion.
  ///
  /// Se guarda el mas viejo y no el ultimo a proposito. Si la pantalla
  /// muestra el tablero de hace diez minutos y los remedios de ayer, lo
  /// honesto es decirle a la persona que hay algo de ayer.
  final DateTime? datoMasViejo;
}

class ConexionController extends Notifier<EstadoDeConexion> {
  @override
  EstadoDeConexion build() => const EstadoDeConexion();

  /// Una peticion no llego al servidor.
  ///
  /// [fechaDelDato] es la del dato guardado que se mostro en su lugar, o nulo
  /// si no habia nada guardado y la pantalla va a mostrar el error.
  void perdida({DateTime? fechaDelDato}) {
    final viejo = state.datoMasViejo;
    state = EstadoDeConexion(
      sinConexion: true,
      datoMasViejo: fechaDelDato == null
          ? viejo
          : (viejo == null || fechaDelDato.isBefore(viejo)
              ? fechaDelDato
              : viejo),
    );
  }

  /// Una peticion llego. Se olvida la fecha, porque lo que se acaba de
  /// mostrar ya es de ahora.
  void recuperada() {
    if (!state.sinConexion && state.datoMasViejo == null) return;
    state = const EstadoDeConexion();
  }
}

final conexionProvider =
    NotifierProvider<ConexionController, EstadoDeConexion>(
        ConexionController.new);

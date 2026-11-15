import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/estado_de_conexion.dart';

/// Franja que avisa que lo que se esta viendo es lo ultimo guardado (RF-80).
///
/// No dice solo "sin conexion". Dice de cuando son los datos, porque es lo
/// que cambia la decision: la cuidadora puede confiar en unos remedios de
/// hace diez minutos y no en los de ayer.
///
/// Mientras hay conexion no ocupa alto, asi que se puede dejar puesta arriba
/// de cualquier pantalla sin condicionarla.
class AvisoSinConexion extends ConsumerWidget {
  const AvisoSinConexion({super.key, this.grande = false});

  /// Version para la vista del adulto mayor: letra grande y una frase corta,
  /// como el resto de esa pantalla (RNF-19).
  final bool grande;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = ref.watch(conexionProvider);
    if (!estado.sinConexion) return const SizedBox.shrink();

    final esquema = Theme.of(context).colorScheme;
    final texto = grande
        ? textoDelAvisoSimple(estado.datoMasViejo)
        : textoDelAviso(estado.datoMasViejo);

    return Container(
      width: double.infinity,
      margin: grande ? const EdgeInsets.only(bottom: 16) : EdgeInsets.zero,
      padding: EdgeInsets.symmetric(
          horizontal: 16, vertical: grande ? 16 : 10),
      decoration: BoxDecoration(
        color: esquema.secondaryContainer,
        borderRadius:
            grande ? BorderRadius.circular(20) : BorderRadius.zero,
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded,
              size: grande ? 30 : 20, color: esquema.onSecondaryContainer),
          SizedBox(width: grande ? 14 : 10),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(
                color: esquema.onSecondaryContainer,
                fontSize: grande ? 19 : 13,
                fontWeight: grande ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// La misma idea en una frase corta, para el adulto mayor.
String textoDelAvisoSimple(DateTime? datoMasViejo) {
  if (datoMasViejo == null) return 'Sin internet.';
  return 'Sin internet. Esto es de las ${_hora(datoMasViejo)}.';
}

const _meses = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

/// La hora y la fecha se arman a mano y no con DateFormat de intl.
///
/// DateFormat con un idioma puesto a mano levanta si no se inicializaron los
/// datos de ese idioma, y este aviso tiene que poder aparecer en cualquier
/// momento, incluso antes de que la app termine de armarse. Para una hora y
/// un mes no vale la pena ese riesgo.
String _hora(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// El texto del aviso, separado para poder probarlo sin dibujar nada.
String textoDelAviso(DateTime? datoMasViejo, {DateTime? ahora}) {
  if (datoMasViejo == null) {
    return 'Sin conexión. No se pudo traer la información más reciente.';
  }
  final hoy = ahora ?? DateTime.now();
  final dias = DateTime(hoy.year, hoy.month, hoy.day)
      .difference(
          DateTime(datoMasViejo.year, datoMasViejo.month, datoMasViejo.day))
      .inDays;
  final cuando = switch (dias) {
    0 => 'de las ${_hora(datoMasViejo)}',
    1 => 'de ayer a las ${_hora(datoMasViejo)}',
    _ => 'del ${datoMasViejo.day} de ${_meses[datoMasViejo.month - 1]} '
        'a las ${_hora(datoMasViejo)}',
  };
  return 'Sin conexión. Estás viendo información guardada $cuando.';
}

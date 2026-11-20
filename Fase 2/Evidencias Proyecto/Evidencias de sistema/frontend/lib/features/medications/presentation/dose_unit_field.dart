import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../domain/models.dart';

/// Selector de la unidad de la dosis.
///
/// Existe como widget propio porque lo usan el formulario del plan y el
/// borrador del escaneo de receta, y cuando cada uno tenia su copia los dos
/// terminaron ofreciendo listas distintas. El escaneo, de hecho, dejaba
/// escribir la unidad a mano, asi que un "miligramos" se guardaba y el
/// backend lo rechazaba por la restriccion, con un error que no se entiende.
///
/// Las opciones van agrupadas porque son dos preguntas distintas. Cuanta
/// sustancia lleva cada toma (50 mg, 2,5 ml), o cuantas unidades se toman
/// (2 comprimidos, 10 gotas). Las cabeceras no se pueden elegir.
class DoseUnitField extends StatelessWidget {
  const DoseUnitField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Unidad',
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue:
          unidadesDeDosis.contains(value) ? value : unidadesDeDosis.first,
      decoration: InputDecoration(labelText: label),
      items: [
        _cabecera('Por medida'),
        for (final u in unidadesDeMedida)
          DropdownMenuItem(value: u, child: Text(u)),
        _cabecera('Por cantidad'),
        for (final u in unidadesDeCantidad)
          DropdownMenuItem(value: u, child: Text(u)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  DropdownMenuItem<String> _cabecera(String texto) => DropdownMenuItem(
        enabled: false,
        child: Text(
          texto,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      );
}

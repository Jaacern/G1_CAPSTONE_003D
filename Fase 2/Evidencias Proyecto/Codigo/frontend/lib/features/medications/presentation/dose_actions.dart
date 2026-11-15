import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/medications_providers.dart';
import '../data/medications_repository.dart';
import '../domain/models.dart';

/// Registra qué pasó con una dosis pidiendo antes lo que exige el backend.
///
/// 6.6 (`POST /doses/{id}/log`) solo admite `taken`, `postponed` y `missed`, y
/// pone condiciones: `missed` necesita un motivo no vacío (si no, 400
/// MISSING_REASON) y `postponed` necesita `postponed_until` dentro de las 4
/// horas siguientes a la hora prevista. Estas reglas viven aquí para que la
/// pantalla del recordatorio y la del plan no las reimplementen cada una.
///
/// Devuelve true si el registro se guardó.
Future<bool> registrarDosis({
  required BuildContext context,
  required WidgetRef ref,
  required Dose dose,
  required DoseStatus status,
}) async {
  String? motivo;
  DateTime? hasta;

  const pideMotivo = {
    DoseStatus.missed,
    DoseStatus.skipped,
    DoseStatus.adverse,
  };
  if (pideMotivo.contains(status)) {
    motivo = await _pedirMotivo(context, status);
    if (motivo == null) return false;
    if (motivo.trim().isEmpty) motivo = 'Sin motivo indicado';
  } else if (status == DoseStatus.postponed) {
    final limite = dose.scheduledAt.add(const Duration(hours: 4));
    final propuesta = DateTime.now().add(const Duration(hours: 1));
    if (!propuesta.isBefore(limite)) {
      if (context.mounted) {
        showAppSnackBar(context,
            'Esta dosis ya no se puede posponer: la ventana de 4 horas cerró.',
            error: true);
      }
      return false;
    }
    hasta = propuesta;
  }

  try {
    await ref.read(medicationsRepositoryProvider).logDose(
          dose.id,
          status,
          note: motivo,
          postponedUntil: hasta,
        );
  } on ApiException catch (e) {
    if (context.mounted) showAppSnackBar(context, e.message, error: true);
    return false;
  } catch (_) {
    if (context.mounted) {
      showAppSnackBar(context, 'No se pudo registrar la dosis.', error: true);
    }
    return false;
  }

  ref.invalidate(todayDosesProvider);
  ref.invalidate(adherenceProvider);

  if (context.mounted) {
    showAppSnackBar(
        context,
        switch (status) {
          DoseStatus.taken => 'Toma registrada',
          DoseStatus.postponed => 'Dosis pospuesta hasta las '
              '${_hora(hasta!)}',
          DoseStatus.adverse =>
            'Registrado el problema. Se avisó al círculo de cuidado.',
          _ => 'Dosis marcada como no tomada',
        });
  }
  return true;
}

String _hora(DateTime? cuando) => cuando == null
    ? ''
    : '${cuando.hour.toString().padLeft(2, '0')}:'
        '${cuando.minute.toString().padLeft(2, '0')}';

/// Cuadro de motivo obligatorio: sin él, el backend rechaza el registro.
///
/// El texto es LIBRE a propósito: la realidad no cabe en una lista cerrada
/// (la vomitó, la escupió, se atragantó, estaba dormida, sin stock...). El
/// título cambia según el desenlace para guiar a la cuidadora.
Future<String?> _pedirMotivo(BuildContext context, DoseStatus status) {
  final controller = TextEditingController();
  final esAdverso = status == DoseStatus.adverse;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(esAdverso ? '¿Qué pasó al administrarla?' : '¿Por qué no la tomó?'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: 'Motivo',
          hintText: esAdverso
              ? 'Por ejemplo: la vomitó a los 10 minutos'
              : 'Por ejemplo: se mareó después del desayuno',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: AppColors.statusAttention),
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
}

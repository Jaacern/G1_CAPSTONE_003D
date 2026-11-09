import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/prn_providers.dart';
import '../domain/prn.dart';

/// Aviso de medicamentos SOS disponibles para un paciente.
///
/// Un SOS no aparece en la agenda de tomas, así que quien cuida no se entera de
/// que existe hasta que lo necesita, que es justo cuando no hay tiempo de
/// buscarlo. Este aviso lo deja a la vista. Si el paciente no tiene SOS, no se
/// dibuja nada.
class PrnBanner extends ConsumerWidget {
  const PrnBanner({super.key, required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lista =
        ref.watch(prnItemsProvider(patientId)).valueOrNull ?? const <PrnItem>[];
    if (lista.isEmpty) return const SizedBox.shrink();
    final hayTope = lista.any((i) => i.alcanzoMaximo);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: AppCard(
        onTap: () => context.push('/meds/sos?patient=$patientId'),
        child: Row(children: [
          const Icon(Icons.emergency_rounded, color: AppColors.statusWarning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Medicamentos SOS disponibles',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(lista.map((i) => i.name).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
                if (hayTope)
                  const Text('Uno llegó al máximo del día',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.critical)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded,
              color: AppColors.textSecondary),
        ]),
      ),
    );
  }
}

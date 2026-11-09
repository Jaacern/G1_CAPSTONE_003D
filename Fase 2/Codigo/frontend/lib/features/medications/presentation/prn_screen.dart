import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/prn_providers.dart';
import '../domain/prn.dart';

/// Medicamentos SOS del paciente: qué hay indicado "solo si se necesita",
/// cuándo se usó por última vez y cuánto se lleva en 24 h.
class PrnScreen extends ConsumerWidget {
  const PrnScreen({super.key, required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(prnItemsProvider(patientId));
    return Scaffold(
      appBar: AppBar(title: const Text('Medicamentos SOS')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const Text(
            'Se dan solo si el paciente los necesita. Anota cada uso con el '
            'motivo: así el médico sabe cuántas veces se usó.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          items.when(
            loading: () => const AppCard(
                child: SizedBox(height: 70, child: LoadingView())),
            error: (_, __) => AppCard(
              child: ErrorView(
                message: 'No se pudieron cargar los medicamentos SOS.',
                onRetry: () => ref.invalidate(prnItemsProvider(patientId)),
              ),
            ),
            data: (lista) => lista.isEmpty
                ? const AppCard(
                    child: Text(
                        'Este paciente no tiene medicamentos SOS indicados.',
                        style: TextStyle(color: AppColors.textSecondary)),
                  )
                : Column(children: [
                    for (final it in lista)
                      _PrnCard(item: it, patientId: patientId),
                  ]),
          ),
        ],
      ),
    );
  }
}

class _PrnCard extends ConsumerWidget {
  const _PrnCard({required this.item, required this.patientId});
  final PrnItem item;
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tope = item.alcanzoMaximo;
    final temprano = item.antesDeTiempo(DateTime.now());
    final detalle = [item.dose, if (item.intervaloLegible != null) item.intervaloLegible!];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.emergency_rounded, color: AppColors.statusWarning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(item.name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(detalle.join(' · '),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if ((item.instructions ?? '').isNotEmpty)
              Text(item.instructions!,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            Text(_ultimoUso(item),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            if (item.maxDaily != null)
              Text(
                'En 24 h: ${_n(item.usedLast24h)} de ${_n(item.maxDaily!)} '
                '${item.doseUnit}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: tope ? FontWeight.w700 : FontWeight.w500,
                    color: tope ? AppColors.critical : AppColors.textSecondary),
              ),
            if (tope)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                    'Se alcanzó el máximo del día. No des otra dosis: '
                    'consulta al médico.',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.critical)),
              )
            else if (temprano)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    'Aún no se cumple el intervalo: desde las '
                    '${_hora(item.nextAllowedAt!)}.',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.statusWarning)),
              ),
          ],
        ),
      ),
    );
  }

  static String _ultimoUso(PrnItem it) => it.lastUsedAt == null
      ? 'Aún no se ha usado.'
      : 'Último uso: ${_hace(it.lastUsedAt!)} (${_hora(it.lastUsedAt!)})';

  static String _hace(DateTime d) {
    final dif = DateTime.now().difference(d);
    if (dif.inMinutes < 1) return 'recién';
    if (dif.inMinutes < 60) return 'hace ${dif.inMinutes} min';
    if (dif.inHours < 24) return 'hace ${dif.inHours} h';
    return 'hace ${dif.inDays} días';
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}

String _hora(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

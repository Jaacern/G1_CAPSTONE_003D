import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/prn_providers.dart';
import '../data/prn_repository.dart';
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
          const SizedBox(height: 16),
          const Text('USOS RECIENTES',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .5,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          _Historial(patientId: patientId),
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
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: tope
                    ? null
                    : () => registrarUsoSos(context, ref, patientId, item),
                icon: const Icon(Icons.add_task_rounded),
                label: const Text('Registrar uso'),
              ),
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


/// Pide el motivo y registra el uso del SOS. El backend valida el máximo de
/// 24 h y el intervalo; aquí solo se muestra lo que responde.
Future<void> registrarUsoSos(BuildContext context, WidgetRef ref,
    String patientId, PrnItem item) async {
  final motivo = await _pedirMotivo(context, item);
  if (motivo == null || !context.mounted) return;
  final repo = ref.read(prnRepositoryProvider);
  try {
    await repo.registerUse(patientId, item.itemId, reason: motivo);
  } on ApiException catch (e) {
    if (e.code != 'PRN_TOO_SOON' || !context.mounted) {
      if (context.mounted) showAppSnackBar(context, e.message, error: true);
      return;
    }
    // Antes del intervalo: se advierte y quien cuida decide si confirma
    // (puede haber una orden médica de repetir). Queda marcado en el registro.
    final seguir = await _confirmarAntesDeTiempo(context, e.message);
    if (seguir != true || !context.mounted) return;
    try {
      await repo.registerUse(patientId, item.itemId,
          reason: motivo, confirmInterval: true);
    } on ApiException catch (e2) {
      if (context.mounted) showAppSnackBar(context, e2.message, error: true);
      return;
    }
  }
  ref.invalidate(prnItemsProvider(patientId));
  ref.invalidate(prnUsesProvider(patientId));
  if (context.mounted) {
    showAppSnackBar(context, 'Uso de ${item.name} registrado.');
  }
}

Future<String?> _pedirMotivo(BuildContext context, PrnItem item) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text('Registrar ${item.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Dosis: ${item.dose}. Queda con la hora de ahora.',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Motivo',
                hintText: 'Ej: le falta el aire',
              ),
              onChanged: (_) => setLocal(() {}),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar')),
          FilledButton(
            onPressed: ctrl.text.trim().length < 3
                ? null
                : () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Registrar'),
          ),
        ],
      ),
    ),
  );
}

Future<bool?> _confirmarAntesDeTiempo(BuildContext context, String mensaje) =>
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.schedule_rounded,
            color: AppColors.statusWarning, size: 32),
        title: const Text('Antes de tiempo'),
        content: Text(mensaje),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('No registrar')),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.statusWarning),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Registrar igual'),
          ),
        ],
      ),
    );

/// Usos de los últimos 7 días: qué se dio, por qué, quién y cuándo.
class _Historial extends ConsumerWidget {
  const _Historial({required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usos = ref.watch(prnUsesProvider(patientId)).valueOrNull ?? const [];
    if (usos.isEmpty) {
      return const AppCard(
        child: Text('Sin usos en los últimos 7 días.',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var i = 0; i < usos.length; i++) ...[
          if (i != 0) const Divider(height: 1),
          ListTile(
            dense: true,
            title: Text('${usos[i].name} · ${usos[i].dose}'),
            subtitle: Text([
              usos[i].reason,
              if (usos[i].loggedByName != null) usos[i].loggedByName!,
              '${usos[i].administeredAt.day}/${usos[i].administeredAt.month} '
                  '${_hora(usos[i].administeredAt)}',
            ].join(' · ')),
            trailing: usos[i].overrodeInterval
                ? const Tooltip(
                    message: 'Antes del intervalo',
                    child: Icon(Icons.schedule_rounded,
                        color: AppColors.statusWarning),
                  )
                : null,
          ),
        ],
      ]),
    );
  }
}

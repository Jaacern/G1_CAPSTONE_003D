import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../shared/widgets.dart';

final summaryProvider = FutureProvider.autoDispose<Summary>(
  (ref) => ref.watch(adminRepositoryProvider).summary(),
);

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(summaryProvider);
    return PageScaffold(
      title: 'Resumen',
      subtitle: 'Estado de la base de usuarios',
      actions: [
        IconButton(
          tooltip: 'Actualizar',
          onPressed: () => ref.invalidate(summaryProvider),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: AsyncBody<Summary>(
        value: value,
        onRetry: () => ref.invalidate(summaryProvider),
        builder: (s) => ListView(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Stat('Cuentas activas', '${s.active}'),
                _Stat('Desactivadas', '${s.inactive}'),
                _Stat('Eliminadas', '${s.deleted}'),
                _Stat(
                  'Conversión',
                  s.conversionPct == null ? '—' : '${s.conversionPct}%',
                  hint: 'planes de pago comprados; sin cortesías',
                ),
                _Stat(
                  'Cobros del mes',
                  fmtMoney(s.monthRevenue, s.currency),
                  hint: '${s.monthCharges} cobros registrados',
                ),
              ],
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Usuarios por plan',
              child: s.byPlan.isEmpty
                  ? const EmptyView('Aún no hay usuarios.')
                  : Column(
                      children: [
                        for (final p in s.byPlan)
                          _Barra(p.label, p.users, s.active),
                      ],
                    ),
            ),
            SectionCard(
              title: 'Cuentas activas por tipo',
              child: s.byType.isEmpty
                  ? const EmptyView('Sin datos.')
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in s.byType.entries)
                          Chip(label: Text('${accountTypeLabel(e.key)}: ${e.value}')),
                      ],
                    ),
            ),
            SectionCard(
              title: 'Altas y bajas (últimos 6 meses)',
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Mes')),
                    DataColumn(label: Text('Altas'), numeric: true),
                    DataColumn(label: Text('Bajas'), numeric: true),
                  ],
                  rows: [
                    for (final m in s.byMonth)
                      DataRow(cells: [
                        DataCell(Text(m.month)),
                        DataCell(Text('${m.signups}')),
                        DataCell(Text('${m.drops}')),
                      ]),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: Text(
                'Las cuentas del personal no se cuentan. Las bajas incluyen cuentas '
                'desactivadas por el personal y eliminadas por su titular.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.hint});
  final String label, value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: 200,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: t.bodyMedium),
              const SizedBox(height: 6),
              Text(value, style: t.headlineMedium),
              if (hint != null) Text(hint!, style: t.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _Barra extends StatelessWidget {
  const _Barra(this.label, this.n, this.total);
  final String label;
  final int n, total;

  @override
  Widget build(BuildContext context) {
    final frac = total == 0 ? 0.0 : (n / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(label)),
          Expanded(
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 10,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          SizedBox(width: 70, child: Text('$n', textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}

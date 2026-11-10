import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../shared/widgets.dart';

final auditProvider = FutureProvider.autoDispose<List<AuditEntry>>(
  (ref) => ref.watch(adminRepositoryProvider).audit(limit: 100),
);

class ActivityPage extends ConsumerWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(auditProvider);
    return PageScaffold(
      title: 'Actividad',
      subtitle: 'Últimas 100 acciones del personal sobre cuentas',
      actions: [
        IconButton(
          tooltip: 'Actualizar',
          onPressed: () => ref.invalidate(auditProvider),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: AsyncBody<List<AuditEntry>>(
        value: value,
        onRetry: () => ref.invalidate(auditProvider),
        builder: (items) => items.isEmpty
            ? const EmptyView('Todavía no hay acciones registradas.', icon: Icons.history)
            : ListView(
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('Fecha')),
                        DataColumn(label: Text('Acción')),
                        DataColumn(label: Text('Cuenta')),
                        DataColumn(label: Text('Responsable')),
                        DataColumn(label: Text('Detalle')),
                      ],
                      rows: [
                        for (final a in items)
                          DataRow(cells: [
                            DataCell(Text(fmtDateTime(a.createdAt))),
                            DataCell(Text(auditActionLabel(a.action))),
                            DataCell(Text(a.targetName ?? '—')),
                            DataCell(Text(a.actorName)),
                            DataCell(Text(a.summary)),
                          ]),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

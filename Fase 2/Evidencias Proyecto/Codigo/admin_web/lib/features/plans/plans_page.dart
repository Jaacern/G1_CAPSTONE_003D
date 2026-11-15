import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../shared/widgets.dart';

class PlansPage extends ConsumerWidget {
  const PlansPage({super.key});

  Future<void> _nuevo(BuildContext context, WidgetRef ref) async {
    final r = await showDialog<_NewPlan>(
      context: context,
      builder: (_) => const _NewPlanDialog(),
    );
    if (r == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(adminRepositoryProvider).createPlan(
            code: r.code,
            name: r.name,
            description: r.description,
            tier: r.tier,
          ),
      okMessage: 'Plan creado en borrador.',
    );
    if (ok) ref.invalidate(plansProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(plansProvider);
    return PageScaffold(
      title: 'Planes',
      subtitle: 'Catálogo comercial: qué incluye y cuánto cuesta cada plan',
      actions: [
        IconButton(
          tooltip: 'Actualizar',
          onPressed: () => ref.invalidate(plansProvider),
          icon: const Icon(Icons.refresh),
        ),
        FilledButton.icon(
          onPressed: () => _nuevo(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Nuevo plan'),
        ),
      ],
      child: AsyncBody<List<PlanItem>>(
        value: value,
        onRetry: () => ref.invalidate(plansProvider),
        builder: (plans) => plans.isEmpty
            ? const EmptyView('No hay planes. Crea el primero.')
            : ListView(children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    showCheckboxColumn: false,
                    columns: const [
                      DataColumn(label: Text('Plan')),
                      DataColumn(label: Text('Código')),
                      DataColumn(label: Text('Estado')),
                      DataColumn(label: Text('Precio mensual')),
                      DataColumn(label: Text('Funciones'), numeric: true),
                      DataColumn(label: Text('Límites'), numeric: true),
                      DataColumn(label: Text('Suscriptores'), numeric: true),
                    ],
                    rows: [
                      for (final p in plans)
                        DataRow(
                          onSelectChanged: (_) => context.go('/planes/${p.id}'),
                          cells: [
                            DataCell(Text(p.name)),
                            DataCell(Text(p.code)),
                            DataCell(StatusChip(planStatusLabel(p.status),
                                tone: switch (p.status) {
                                  'active' => Tone.good,
                                  'draft' => Tone.warn,
                                  _ => Tone.neutral,
                                })),
                            DataCell(Text(p.tier == 0
                                ? 'Gratis'
                                : fmtMoney(p.price, p.currency))),
                            DataCell(Text('${p.features}')),
                            DataCell(Text('${p.limits}')),
                            DataCell(Text('${p.subscribers}')),
                          ],
                        ),
                    ],
                  ),
                ),
              ]),
      ),
    );
  }
}

class _NewPlan {
  _NewPlan(this.code, this.name, this.description, this.tier);
  final String code, name;
  final String? description;
  final int tier;
}

class _NewPlanDialog extends StatefulWidget {
  const _NewPlanDialog();

  @override
  State<_NewPlanDialog> createState() => _NewPlanDialogState();
}

class _NewPlanDialogState extends State<_NewPlanDialog> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _tier = TextEditingController(text: '1');

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _desc.dispose();
    _tier.dispose();
    super.dispose();
  }

  void _ok() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      _NewPlan(_code.text.trim(), _name.text.trim(), _desc.text.trim(),
          int.parse(_tier.text.trim())),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nuevo plan'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: _code,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Código',
                  helperText: 'Minúsculas, números y _. No se puede cambiar después.',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => RegExp(r'^[a-z][a-z0-9_]{2,19}$').hasMatch(v ?? '')
                    ? null
                    : 'De 3 a 20 caracteres, empieza con letra.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                maxLength: 60,
                decoration: const InputDecoration(
                    labelText: 'Nombre', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Escribe un nombre.' : null,
              ),
              TextFormField(
                controller: _desc,
                maxLength: 300,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: 'Descripción (opcional)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tier,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Jerarquía (0 = gratuito)',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  return (n == null || n < 0 || n > 10) ? 'Un número de 0 a 10.' : null;
                },
              ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _ok, child: const Text('Crear')),
      ],
    );
  }
}

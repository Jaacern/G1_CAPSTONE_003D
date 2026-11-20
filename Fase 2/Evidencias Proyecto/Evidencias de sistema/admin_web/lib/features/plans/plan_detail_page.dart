import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../shared/widgets.dart';

final planDetailProvider = FutureProvider.autoDispose.family<PlanDetail, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).planDetail(id),
);

const _unidades = {
  'count': '',
  'days': 'días',
  'months': 'meses',
  'megabytes': 'MB',
  'per_month': 'por mes',
  'per_day': 'por día',
};

String _textoLimite(PlanLimit l) {
  if (!l.isSet) return 'Sin definir';
  if (l.value == null) return 'Sin tope';
  if (l.value == 0) return 'No incluido';
  final u = _unidades[l.unit] ?? '';
  return u.isEmpty ? '${l.value}' : '${l.value} $u';
}

class PlanDetailPage extends ConsumerWidget {
  const PlanDetailPage({super.key, required this.planId});
  final String planId;

  AdminRepository _repo(WidgetRef ref) => ref.read(adminRepositoryProvider);

  void _refrescar(WidgetRef ref) {
    ref.invalidate(planDetailProvider(planId));
    ref.invalidate(plansProvider);
  }

  Future<void> _accion(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() fn, {
    String? ok,
  }) async {
    if (await runAction(context, fn, okMessage: ok)) _refrescar(ref);
  }

  Future<void> _editar(BuildContext context, WidgetRef ref, PlanItem p) async {
    final r = await showDialog<_EditPlan>(
      context: context,
      builder: (_) => _EditPlanDialog(plan: p),
    );
    if (r == null || !context.mounted) return;
    await _accion(
      context,
      ref,
      () => _repo(ref).editPlan(
        planId,
        name: r.name,
        description: r.description.isEmpty ? null : r.description,
        tier: r.tier,
        isPublic: r.isPublic,
      ),
      ok: 'Plan actualizado.',
    );
  }

  Future<void> _publicar(BuildContext context, WidgetRef ref, PlanItem p) async {
    final ok = await confirm(
      context,
      title: 'Publicar plan',
      message: '"${p.name}" quedará disponible para contratar. Un plan de pago '
          'necesita un precio vigente. Las funciones del núcleo se agregan solas.',
      confirmLabel: 'Publicar',
    );
    if (!ok || !context.mounted) return;
    await _accion(context, ref, () => _repo(ref).publishPlan(planId), ok: 'Plan publicado.');
  }

  Future<void> _archivar(BuildContext context, WidgetRef ref, PlanItem p) async {
    final ok = await confirm(
      context,
      title: 'Archivar plan',
      message: 'Dejará de ofrecerse y no se podrá volver a publicar. '
          '${p.subscribers} suscriptores activos lo conservan.',
      confirmLabel: 'Archivar',
    );
    if (!ok || !context.mounted) return;
    await _accion(context, ref, () => _repo(ref).archivePlan(planId), ok: 'Plan archivado.');
  }

  Future<void> _nuevoPrecio(BuildContext context, WidgetRef ref) async {
    final r = await showDialog<_NewPrice>(
      context: context,
      builder: (_) => const _NewPriceDialog(),
    );
    if (r == null || !context.mounted) return;
    await _accion(
      context,
      ref,
      () => _repo(ref).newPrice(planId,
          period: r.period, amount: r.amount, currency: r.currency),
      ok: 'Precio actualizado.',
    );
  }

  Future<void> _editarLimite(BuildContext context, WidgetRef ref, PlanLimit l) async {
    final r = await showDialog<_LimitChoice>(
      context: context,
      builder: (_) => _LimitDialog(limit: l),
    );
    if (r == null || !context.mounted) return;
    await _accion(context, ref, () => _repo(ref).setLimit(planId, l.key, r.value),
        ok: 'Límite guardado.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(planDetailProvider(planId));
    final d = value.valueOrNull;
    final p = d?.plan;

    return PageScaffold(
      title: p?.name ?? 'Plan',
      subtitle: p == null ? null : '${p.code} · ${planStatusLabel(p.status)}',
      leading: IconButton(
        tooltip: 'Volver',
        onPressed: () => context.go('/planes'),
        icon: const Icon(Icons.arrow_back),
      ),
      actions: [
        if (p != null && p.status != 'archived')
          OutlinedButton.icon(
            onPressed: () => _editar(context, ref, p),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Editar'),
          ),
        if (p != null && p.status == 'draft')
          FilledButton.icon(
            onPressed: () => _publicar(context, ref, p),
            icon: const Icon(Icons.publish),
            label: const Text('Publicar'),
          ),
        if (p != null && p.status == 'active')
          OutlinedButton.icon(
            onPressed: () => _archivar(context, ref, p),
            icon: const Icon(Icons.archive_outlined),
            label: const Text('Archivar'),
          ),
      ],
      child: AsyncBody<PlanDetail>(
        value: value,
        onRetry: () => ref.invalidate(planDetailProvider(planId)),
        builder: (d) {
          final editable = d.plan.status != 'archived';
          final modulos = <String, List<PlanFeature>>{};
          for (final f in d.features) {
            modulos.putIfAbsent(f.module, () => []).add(f);
          }
          return ListView(children: [
            SectionCard(
              title: 'General',
              child: Column(children: [
                KeyValue('Descripción', d.plan.description ?? '—'),
                KeyValue('Jerarquía', d.plan.tier == 0 ? '0 (gratuito)' : '${d.plan.tier}'),
                KeyValue('Visible al público', d.plan.isPublic ? 'Sí' : 'No'),
                KeyValue('Suscriptores activos', '${d.plan.subscribers}'),
              ]),
            ),
            SectionCard(
              title: 'Precios',
              trailing: editable && d.plan.tier > 0
                  ? TextButton.icon(
                      onPressed: () => _nuevoPrecio(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('Nuevo precio'),
                    )
                  : null,
              child: d.prices.isEmpty
                  ? EmptyView(d.plan.tier == 0
                      ? 'El plan gratuito no tiene precio.'
                      : 'Sin precio. Agrega uno antes de publicar.')
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Periodo')),
                          DataColumn(label: Text('Monto')),
                          DataColumn(label: Text('Desde')),
                          DataColumn(label: Text('Hasta')),
                        ],
                        rows: [
                          for (final x in d.prices)
                            DataRow(cells: [
                              DataCell(Text(periodLabel(x.period))),
                              DataCell(Text(fmtMoney(x.amount, x.currency))),
                              DataCell(Text(fmtDateTime(x.validFrom))),
                              DataCell(Text(x.validTo == null ? 'Vigente' : fmtDateTime(x.validTo))),
                            ]),
                        ],
                      ),
                    ),
            ),
            SectionCard(
              title: 'Límites',
              child: Column(children: [
                for (final l in d.limits)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.label),
                    subtitle: Text(l.description),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_textoLimite(l)),
                      if (editable) ...[
                        IconButton(
                          tooltip: 'Editar',
                          onPressed: () => _editarLimite(context, ref, l),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                        IconButton(
                          tooltip: 'Quitar',
                          onPressed: l.isSet
                              ? () => _accion(context, ref,
                                  () => _repo(ref).clearLimit(planId, l.key),
                                  ok: 'Límite quitado.')
                              : null,
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ]),
                  ),
              ]),
            ),
            SectionCard(
              title: 'Funcionalidades',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in modulos.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(e.key.toUpperCase(),
                          style: Theme.of(context).textTheme.labelMedium),
                    ),
                    for (final f in e.value)
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Row(children: [
                          Flexible(child: Text(f.label)),
                          if (f.isCore) ...[
                            const SizedBox(width: 8),
                            const StatusChip('Núcleo'),
                          ],
                        ]),
                        subtitle: Text(f.description),
                        value: f.included,
                        // Las del núcleo no se pueden quitar de ningún plan.
                        onChanged: (!editable || (f.isCore && f.included))
                            ? null
                            : (v) => _accion(context, ref,
                                () => _repo(ref).setFeature(planId, f.code, v)),
                      ),
                  ],
                ],
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ── Diálogos ────────────────────────────────────────────────────────────
class _EditPlan {
  _EditPlan(this.name, this.description, this.tier, this.isPublic);
  final String name, description;
  final int tier;
  final bool isPublic;
}

class _EditPlanDialog extends StatefulWidget {
  const _EditPlanDialog({required this.plan});
  final PlanItem plan;

  @override
  State<_EditPlanDialog> createState() => _EditPlanDialogState();
}

class _EditPlanDialogState extends State<_EditPlanDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.plan.name);
  late final _desc = TextEditingController(text: widget.plan.description ?? '');
  late final _tier = TextEditingController(text: '${widget.plan.tier}');
  late bool _public = widget.plan.isPublic;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _tier.dispose();
    super.dispose();
  }

  void _ok() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      _EditPlan(_name.text.trim(), _desc.text.trim(), int.parse(_tier.text.trim()), _public),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar plan'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    labelText: 'Descripción', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tier,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Jerarquía (0 = gratuito)', border: OutlineInputBorder()),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  return (n == null || n < 0 || n > 10) ? 'Un número de 0 a 10.' : null;
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Visible al público'),
                value: _public,
                onChanged: (v) => setState(() => _public = v),
              ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _ok, child: const Text('Guardar')),
      ],
    );
  }
}

class _NewPrice {
  _NewPrice(this.period, this.amount, this.currency);
  final String period, currency;
  final num amount;
}

class _NewPriceDialog extends StatefulWidget {
  const _NewPriceDialog();

  @override
  State<_NewPriceDialog> createState() => _NewPriceDialogState();
}

class _NewPriceDialogState extends State<_NewPriceDialog> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  String _period = 'monthly';

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _ok() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      _NewPrice(_period, num.parse(_amount.text.trim().replaceAll(',', '.')), 'CLP'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nuevo precio'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('El precio actual se cierra hoy y este pasa a ser el vigente. '
                'Los cobros anteriores no cambian.'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _period,
              decoration: const InputDecoration(
                  labelText: 'Periodo', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'monthly', child: Text('Mensual')),
                DropdownMenuItem(value: 'yearly', child: Text('Anual')),
                DropdownMenuItem(value: 'once', child: Text('Pago único')),
              ],
              onChanged: (v) => setState(() => _period = v ?? 'monthly'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Monto (CLP)', prefixText: '\$ ', border: OutlineInputBorder()),
              validator: (v) {
                final n = num.tryParse((v ?? '').trim().replaceAll(',', '.'));
                return (n == null || n < 0) ? 'Ingresa un monto válido.' : null;
              },
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _ok, child: const Text('Guardar')),
      ],
    );
  }
}

class _LimitChoice {
  _LimitChoice(this.value);
  final int? value; // null = sin tope
}

class _LimitDialog extends StatefulWidget {
  const _LimitDialog({required this.limit});
  final PlanLimit limit;

  @override
  State<_LimitDialog> createState() => _LimitDialogState();
}

class _LimitDialogState extends State<_LimitDialog> {
  final _form = GlobalKey<FormState>();
  late bool _sinTope = widget.limit.isSet && widget.limit.value == null;
  late final _value = TextEditingController(
      text: widget.limit.value == null ? '' : '${widget.limit.value}');

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _ok() {
    if (_sinTope) {
      Navigator.pop(context, _LimitChoice(null));
      return;
    }
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, _LimitChoice(int.parse(_value.text.trim())));
  }

  @override
  Widget build(BuildContext context) {
    final u = _unidades[widget.limit.unit] ?? '';
    return AlertDialog(
      title: Text(widget.limit.label),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.limit.description),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sin tope'),
              value: _sinTope,
              onChanged: (v) => setState(() => _sinTope = v),
            ),
            if (!_sinTope)
              TextFormField(
                controller: _value,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Valor',
                  helperText: '0 = no incluido',
                  suffixText: u,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  return (n == null || n < 0) ? 'Un número entero, 0 o mayor.' : null;
                },
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _ok, child: const Text('Guardar')),
      ],
    );
  }
}

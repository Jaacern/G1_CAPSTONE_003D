import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../shared/widgets.dart';
import 'users_page.dart' show usersPageProvider;

final userDetailProvider = FutureProvider.autoDispose.family<UserDetail, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).user(id),
);

class UserDetailPage extends ConsumerWidget {
  const UserDetailPage({super.key, required this.userId});
  final String userId;

  void _refrescar(WidgetRef ref) {
    ref.invalidate(userDetailProvider(userId));
    ref.invalidate(usersPageProvider);
  }

  Future<void> _asignarPlan(BuildContext context, WidgetRef ref, UserDetail u) async {
    final plans = (await ref.read(plansProvider.future)).where((p) => p.isActive).toList();
    if (!context.mounted) return;
    final r = await showDialog<_PlanChoice>(
      context: context,
      builder: (_) => _AssignPlanDialog(plans: plans, current: u.planCode),
    );
    if (r == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(adminRepositoryProvider).assignPlan(
            userId,
            planCode: r.planCode,
            validUntil: r.validUntil,
            reason: r.reason,
          ),
      okMessage: 'Plan actualizado.',
    );
    if (ok) _refrescar(ref);
  }

  Future<void> _desactivar(BuildContext context, WidgetRef ref, UserDetail u) async {
    final motivo = await askReason(
      context,
      title: 'Desactivar cuenta',
      message: '${u.fullName} no podrá iniciar sesión y se cerrarán sus sesiones. '
          'No se borra nada y se puede reactivar.',
      confirmLabel: 'Desactivar',
      destructive: true,
    );
    if (motivo == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(adminRepositoryProvider).deactivate(userId, motivo),
      okMessage: 'Cuenta desactivada.',
    );
    if (ok) _refrescar(ref);
  }

  Future<void> _reactivar(BuildContext context, WidgetRef ref, UserDetail u) async {
    final ok = await confirm(
      context,
      title: 'Reactivar cuenta',
      message: '${u.fullName} podrá volver a iniciar sesión.',
      confirmLabel: 'Reactivar',
    );
    if (!ok || !context.mounted) return;
    final hecho = await runAction(
      context,
      () => ref.read(adminRepositoryProvider).reactivate(userId),
      okMessage: 'Cuenta reactivada.',
    );
    if (hecho) _refrescar(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(userDetailProvider(userId));
    final u = value.valueOrNull;

    return PageScaffold(
      title: u?.fullName ?? 'Usuario',
      subtitle: u?.email,
      leading: IconButton(
        tooltip: 'Volver',
        onPressed: () => context.go('/usuarios'),
        icon: const Icon(Icons.arrow_back),
      ),
      actions: [
        if (u != null && u.status != 'deleted') ...[
          OutlinedButton.icon(
            onPressed: () => _asignarPlan(context, ref, u),
            icon: const Icon(Icons.card_giftcard),
            label: const Text('Cortesía o corrección'),
          ),
          if (u.status == 'active')
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => _desactivar(context, ref, u),
              icon: const Icon(Icons.block),
              label: const Text('Desactivar'),
            )
          else
            FilledButton.icon(
              onPressed: () => _reactivar(context, ref, u),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Reactivar'),
            ),
        ],
      ],
      child: AsyncBody<UserDetail>(
        value: value,
        onRetry: () => ref.invalidate(userDetailProvider(userId)),
        builder: (u) => ListView(
          children: [
            if (u.status == 'inactive')
              _Aviso(
                'Cuenta desactivada el ${fmtDateTime(u.deactivatedAt)}'
                '${u.deactivatedBy == null ? '' : ' por ${u.deactivatedBy}'}. '
                'Motivo: ${u.deactivatedReason ?? '—'}',
              ),
            if (u.status == 'deleted')
              const _Aviso('La cuenta fue eliminada por su titular. No se puede '
                  'reactivar ni cambiar su plan desde aquí.'),
            SectionCard(
              title: 'Cuenta',
              child: Column(children: [
                KeyValue('Estado', userStatusLabel(u.status)),
                KeyValue('Tipo', accountTypeLabel(u.accountType)),
                KeyValue('Teléfono', u.phone ?? '—'),
                KeyValue('Alta', fmtDateTime(u.createdAt)),
                KeyValue('Última sesión', fmtDateTime(u.lastSession)),
                KeyValue('Pacientes', '${u.patients}'),
                if (u.isStaff) const KeyValue('Rol', 'Personal de Alloxentric'),
              ]),
            ),
            SectionCard(
              title: 'Plan vigente',
              child: Column(children: [
                KeyValue('Plan', u.planName),
                KeyValue(
                  'Origen',
                  u.planCode == 'free'
                      ? 'Plan gratuito'
                      : (u.subscriptions.any((s) => s.status == 'active' && s.isCourtesy)
                          ? 'Cortesía del personal'
                          : 'Compra del usuario'),
                ),
                KeyValue('Vence', u.planEnds == null ? 'Sin fecha de término' : fmtDate(u.planEnds)),
              ]),
            ),
            SectionCard(
              title: 'Historial de suscripciones',
              child: u.subscriptions.isEmpty
                  ? const EmptyView('Sin suscripciones. La cuenta siempre fue gratuita.')
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Plan')),
                          DataColumn(label: Text('Estado')),
                          DataColumn(label: Text('Inicio')),
                          DataColumn(label: Text('Fin')),
                          DataColumn(label: Text('Origen')),
                        ],
                        rows: [
                          for (final s in u.subscriptions)
                            DataRow(cells: [
                              DataCell(Text(s.planName)),
                              DataCell(Text(s.status)),
                              DataCell(Text(fmtDate(s.startedAt))),
                              DataCell(Text(fmtDate(s.cancelledAt ?? s.periodEnd))),
                              DataCell(Text(s.isCourtesy
                                  ? 'Cortesía · ${s.grantedBy ?? '—'}'
                                      '${s.reason == null ? '' : ' · ${s.reason}'}'
                                  : 'Compra'
                                      '${s.cancelRequestedAt == null ? '' : ' · no renueva (pedido el ${fmtDate(s.cancelRequestedAt)})'}'
                                      '${s.reason == null ? '' : ' · ${s.reason}'}')),
                            ]),
                        ],
                      ),
                    ),
            ),
            SectionCard(
              title: 'Pagos y cambios de plan',
              child: u.payments.isEmpty
                  ? const EmptyView('Sin movimientos de facturación.')
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Fecha')),
                          DataColumn(label: Text('Movimiento')),
                          DataColumn(label: Text('Plan')),
                          DataColumn(label: Text('Monto')),
                          DataColumn(label: Text('Referencia')),
                        ],
                        rows: [
                          for (final p in u.payments)
                            DataRow(cells: [
                              DataCell(Text(fmtDateTime(p.occurredAt))),
                              DataCell(Text(billingTypeLabel(p.type) +
                                  (p.status == 'failed'
                                      ? ' (${p.failureReason ?? 'fallido'})'
                                      : ''))),
                              DataCell(Text(p.planName)),
                              DataCell(Text(p.amount == null
                                  ? '—'
                                  : fmtMoney(p.amount, p.currency))),
                              DataCell(Text(p.providerRef == null
                                  ? '—'
                                  : (p.isSimulated
                                      ? '${p.providerRef} (simulado)'
                                      : p.providerRef!))),
                            ]),
                        ],
                      ),
                    ),
            ),
            SectionCard(
              title: 'Acciones del personal',
              child: u.audit.isEmpty
                  ? const EmptyView('Sin acciones registradas.')
                  : Column(children: [
                      for (final a in u.audit)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(auditActionLabel(a.action)),
                          subtitle: Text('${a.actorName} · ${a.summary}'),
                          trailing: Text(fmtDateTime(a.createdAt)),
                        ),
                    ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: s.onTertiaryContainer)),
    );
  }
}

class _PlanChoice {
  _PlanChoice(this.planCode, this.validUntil, this.reason);
  final String planCode;
  final DateTime? validUntil;
  final String reason;
}

class _AssignPlanDialog extends StatefulWidget {
  const _AssignPlanDialog({required this.plans, required this.current});
  final List<PlanItem> plans;
  final String current;

  @override
  State<_AssignPlanDialog> createState() => _AssignPlanDialogState();
}

class _AssignPlanDialogState extends State<_AssignPlanDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();
  String? _code;
  DateTime? _until;

  @override
  void initState() {
    super.initState();
    _code = widget.plans.any((p) => p.code == widget.current) ? widget.current : null;
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  PlanItem? get _plan {
    for (final p in widget.plans) {
      if (p.code == _code) return p;
    }
    return null;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _until ?? now.add(const Duration(days: 30)),
      firstDate: now.add(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (d != null) {
      // Fin del día elegido, hora local.
      setState(() => _until = DateTime(d.year, d.month, d.day, 23, 59));
    }
  }

  void _ok() {
    if (!_form.currentState!.validate()) return;
    final paga = (_plan?.tier ?? 0) > 0;
    Navigator.pop(context, _PlanChoice(_code!, paga ? _until : null, _reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final paga = (_plan?.tier ?? 0) > 0;
    return AlertDialog(
      title: const Text('Cortesía o corrección'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('El plan normal lo define la compra del usuario. Usa esto '
                  'solo para una cortesía, una compensación o para corregir un '
                  'cobro. Queda registrado con tu nombre y el motivo.'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _code,
                decoration: const InputDecoration(
                    labelText: 'Plan', border: OutlineInputBorder()),
                items: [
                  for (final p in widget.plans)
                    DropdownMenuItem(
                      value: p.code,
                      child: Text(p.code == widget.current ? '${p.name} (actual)' : p.name),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _code = v;
                  _until = null;
                }),
                validator: (v) => v == null ? 'Elige un plan.' : null,
              ),
              if (paga) ...[
                const SizedBox(height: 12),
                FormField<DateTime>(
                  validator: (_) =>
                      _until == null ? 'Elige hasta cuándo dura la cortesía.' : null,
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(_until == null
                              ? 'Sin fecha de término'
                              : 'Hasta ${fmtDate(_until)}'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await _pickDate();
                            state.didChange(_until);
                          },
                          child: const Text('Elegir fecha'),
                        ),
                      ]),
                      if (state.hasError)
                        Text(state.errorText!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12)),
                    ],
                  ),
                ),
              ] else if (_code != null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('El plan gratuito cierra la suscripción de pago actual.'),
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reason,
                maxLength: 200,
                decoration: const InputDecoration(
                    labelText: 'Motivo', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().length < 3)
                    ? 'Escribe un motivo (mínimo 3 caracteres).'
                    : null,
              ),
            ],
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

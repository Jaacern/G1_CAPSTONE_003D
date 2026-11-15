import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/format.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../shared/widgets.dart';

final doctorsProvider = FutureProvider.autoDispose<List<DoctorItem>>(
  (ref) => ref.watch(adminRepositoryProvider).doctors(),
);

class DoctorsPage extends ConsumerWidget {
  const DoctorsPage({super.key});

  Future<void> _habilitar(BuildContext context, WidgetRef ref) async {
    final r = await showDialog<Enrollment>(
      context: context,
      builder: (_) => _EnrollDialog(repo: ref.read(adminRepositoryProvider)),
    );
    if (r == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TokenDialog(enrollment: r),
    );
  }

  Future<void> _revocar(BuildContext context, WidgetRef ref, DoctorItem d) async {
    final motivo = await askReason(
      context,
      title: 'Revocar habilitación',
      message: '${d.fullName} perderá el acceso clínico a todos sus pacientes.',
      confirmLabel: 'Revocar',
      destructive: true,
    );
    if (motivo == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(adminRepositoryProvider).revokeDoctor(d.userId, motivo),
      okMessage: 'Habilitación revocada.',
    );
    if (ok) ref.invalidate(doctorsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(doctorsProvider);
    return PageScaffold(
      title: 'Médicos',
      subtitle: 'Habilitación tras verificar el registro profesional',
      actions: [
        IconButton(
          tooltip: 'Actualizar',
          onPressed: () => ref.invalidate(doctorsProvider),
          icon: const Icon(Icons.refresh),
        ),
        FilledButton.icon(
          onPressed: () => _habilitar(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Habilitar médico'),
        ),
      ],
      child: AsyncBody<List<DoctorItem>>(
        value: value,
        onRetry: () => ref.invalidate(doctorsProvider),
        builder: (items) => items.isEmpty
            ? const EmptyView('Aún no hay médicos habilitados.')
            : ListView(children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Nombre')),
                      DataColumn(label: Text('Correo')),
                      DataColumn(label: Text('Registro')),
                      DataColumn(label: Text('Especialidad')),
                      DataColumn(label: Text('Estado')),
                      DataColumn(label: Text('')),
                    ],
                    rows: [
                      for (final d in items)
                        DataRow(cells: [
                          DataCell(Text(d.fullName)),
                          DataCell(Text(d.email)),
                          DataCell(Text(d.license)),
                          DataCell(Text(d.specialty ?? '—')),
                          DataCell(d.revoked
                              ? StatusChip('Revocado ${fmtDate(d.revokedAt)}', tone: Tone.bad)
                              : StatusChip('Habilitado ${fmtDate(d.verifiedAt)}',
                                  tone: Tone.good)),
                          DataCell(d.revoked
                              ? const SizedBox.shrink()
                              : TextButton(
                                  onPressed: () => _revocar(context, ref, d),
                                  child: const Text('Revocar'),
                                )),
                        ]),
                    ],
                  ),
                ),
              ]),
      ),
    );
  }
}

class _EnrollDialog extends StatefulWidget {
  const _EnrollDialog({required this.repo});
  final AdminRepository repo;

  @override
  State<_EnrollDialog> createState() => _EnrollDialogState();
}

class _EnrollDialogState extends State<_EnrollDialog> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _license = TextEditingController();
  final _specialty = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _license.dispose();
    _specialty.dispose();
    super.dispose();
  }

  Future<void> _ok() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.repo.enrollDoctor(
        email: _email.text.trim(),
        license: _license.text.trim(),
        specialty: _specialty.text.trim(),
      );
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = ApiException.from(e).display;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Habilitar médico'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Verifica antes el registro en la Superintendencia de Salud. '
                  'Se emite un código de un solo uso, ligado a este correo.'),
              const SizedBox(height: 12),
              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: scheme.error)),
                const SizedBox(height: 8),
              ],
              TextFormField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Correo', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || !v.contains('@')) ? 'Ingresa un correo válido.' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _license,
                decoration: const InputDecoration(
                    labelText: 'Número de registro', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().length < 3)
                    ? 'Ingresa el número de registro.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _specialty,
                decoration: const InputDecoration(
                    labelText: 'Especialidad (opcional)', border: OutlineInputBorder()),
              ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: _busy ? null : _ok,
            child: _busy
                ? const SizedBox(
                    height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Emitir código')),
      ],
    );
  }
}

class _TokenDialog extends StatelessWidget {
  const _TokenDialog({required this.enrollment});
  final Enrollment enrollment;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Código emitido'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Para ${enrollment.email} (registro ${enrollment.license}). '
              'Vence el ${fmtDate(enrollment.expiresAt)}.'),
          const SizedBox(height: 12),
          const Text('Cópialo ahora: no se vuelve a mostrar.'),
          const SizedBox(height: 8),
          SelectableText(enrollment.token,
              style: const TextStyle(fontFamily: 'monospace')),
        ]),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: enrollment.token));
            if (context.mounted) showOk(context, 'Código copiado.');
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copiar'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Listo')),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../shared/widgets.dart';

final catalogFeaturesProvider = FutureProvider.autoDispose<List<CatalogFeature>>(
  (ref) => ref.watch(adminRepositoryProvider).catalogFeatures(),
);

final catalogLimitsProvider = FutureProvider.autoDispose<List<CatalogLimit>>(
  (ref) => ref.watch(adminRepositoryProvider).catalogLimits(),
);

const _modulos = {
  'health': 'Salud',
  'medication': 'Medicación',
  'alerts': 'Alertas',
  'logbook': 'Bitácora',
  'documents': 'Documentos',
  'chat': 'Chat',
  'assistant': 'Asistente',
  'elder': 'Adulto mayor',
  'marketplace': 'Marketplace',
  'reports': 'Reportes',
};

const _unidades = {
  'count': 'Cantidad',
  'days': 'Días',
  'months': 'Meses',
  'megabytes': 'Megabytes',
  'per_month': 'Por mes',
  'per_day': 'Por día',
};

/// Funcionalidades y límites que un plan puede incluir.
/// Crear una no la agrega a ningún plan: se decide plan por plan.
class CatalogPage extends ConsumerWidget {
  const CatalogPage({super.key});

  Future<void> _crear(BuildContext context, WidgetRef ref, {required bool feature}) async {
    final r = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CatalogDialog(feature: feature),
    );
    if (r == null || !context.mounted) return;
    final repo = ref.read(adminRepositoryProvider);
    final ok = await runAction(
      context,
      () => feature
          ? repo.createFeature(
              code: r['code'],
              label: r['label'],
              description: r['description'],
              module: r['module'],
              isCore: r['is_core'],
            )
          : repo.createLimit(
              key: r['code'],
              label: r['label'],
              description: r['description'],
              unit: r['unit'],
            ),
      okMessage: feature ? 'Funcionalidad creada.' : 'Límite creado.',
    );
    if (ok) {
      ref.invalidate(feature ? catalogFeaturesProvider : catalogLimitsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: PageScaffold(
        title: 'Catálogo',
        subtitle: 'Lo que se puede incluir o limitar en un plan',
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: TabBar(
                isScrollable: true,
                tabs: [Tab(text: 'Funcionalidades'), Tab(text: 'Límites')],
              ),
            ),
            Expanded(
              child: TabBarView(children: [
                _FeaturesTab(onNew: () => _crear(context, ref, feature: true)),
                _LimitsTab(onNew: () => _crear(context, ref, feature: false)),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeaturesTab extends ConsumerWidget {
  const _FeaturesTab({required this.onNew});
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(children: [
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add),
            label: const Text('Nueva funcionalidad'),
          ),
        ),
      ),
      Expanded(
        child: AsyncBody<List<CatalogFeature>>(
          value: ref.watch(catalogFeaturesProvider),
          onRetry: () => ref.invalidate(catalogFeaturesProvider),
          builder: (items) => items.isEmpty
              ? const EmptyView('No hay funcionalidades.')
              : ListView(children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('Nombre')),
                        DataColumn(label: Text('Código')),
                        DataColumn(label: Text('Módulo')),
                        DataColumn(label: Text('Núcleo')),
                        DataColumn(label: Text('Planes'), numeric: true),
                      ],
                      rows: [
                        for (final f in items)
                          DataRow(cells: [
                            DataCell(Tooltip(message: f.description, child: Text(f.label))),
                            DataCell(Text(f.code)),
                            DataCell(Text(_modulos[f.module] ?? f.module)),
                            DataCell(Text(f.isCore ? 'Sí' : 'No')),
                            DataCell(Text('${f.plans}')),
                          ]),
                      ],
                    ),
                  ),
                ]),
        ),
      ),
    ]);
  }
}

class _LimitsTab extends ConsumerWidget {
  const _LimitsTab({required this.onNew});
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(children: [
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add),
            label: const Text('Nuevo límite'),
          ),
        ),
      ),
      Expanded(
        child: AsyncBody<List<CatalogLimit>>(
          value: ref.watch(catalogLimitsProvider),
          onRetry: () => ref.invalidate(catalogLimitsProvider),
          builder: (items) => items.isEmpty
              ? const EmptyView('No hay límites.')
              : ListView(children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('Nombre')),
                        DataColumn(label: Text('Clave')),
                        DataColumn(label: Text('Unidad')),
                        DataColumn(label: Text('Planes'), numeric: true),
                      ],
                      rows: [
                        for (final l in items)
                          DataRow(cells: [
                            DataCell(Tooltip(message: l.description, child: Text(l.label))),
                            DataCell(Text(l.key)),
                            DataCell(Text(_unidades[l.unit] ?? l.unit)),
                            DataCell(Text('${l.plans}')),
                          ]),
                      ],
                    ),
                  ),
                ]),
        ),
      ),
    ]);
  }
}

class _CatalogDialog extends StatefulWidget {
  const _CatalogDialog({required this.feature});
  final bool feature;

  @override
  State<_CatalogDialog> createState() => _CatalogDialogState();
}

class _CatalogDialogState extends State<_CatalogDialog> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _label = TextEditingController();
  final _desc = TextEditingController();
  late String _choice = widget.feature ? 'health' : 'count';
  bool _core = false;

  @override
  void dispose() {
    _code.dispose();
    _label.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _ok() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, {
      'code': _code.text.trim(),
      'label': _label.text.trim(),
      'description': _desc.text.trim(),
      if (widget.feature) 'module': _choice else 'unit': _choice,
      'is_core': _core,
    });
  }

  @override
  Widget build(BuildContext context) {
    final opciones = widget.feature ? _modulos : _unidades;
    return AlertDialog(
      title: Text(widget.feature ? 'Nueva funcionalidad' : 'Nuevo límite'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: _code,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: widget.feature ? 'Código' : 'Clave',
                  helperText: 'Minúsculas, números y _ (3 a 40 caracteres).',
                  border: const OutlineInputBorder(),
                ),
                validator: (v) => RegExp(r'^[a-z][a-z0-9_]{2,39}$').hasMatch(v ?? '')
                    ? null
                    : 'Formato inválido.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _label,
                maxLength: 80,
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
                  labelText: 'Descripción',
                  helperText: 'La ve el cliente al comparar planes.',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Escribe una descripción.' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _choice,
                decoration: InputDecoration(
                  labelText: widget.feature ? 'Módulo' : 'Unidad',
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final e in opciones.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _choice = v ?? _choice),
              ),
              if (widget.feature)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Del núcleo'),
                  subtitle: const Text('Ningún plan podrá quitarla.'),
                  value: _core,
                  onChanged: (v) => setState(() => _core = v),
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

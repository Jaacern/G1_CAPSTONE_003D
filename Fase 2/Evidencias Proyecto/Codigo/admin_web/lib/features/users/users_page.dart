import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../shared/widgets.dart';

const _pageSize = 25;

class UsersQuery {
  const UsersQuery({
    this.q = '',
    this.status = 'all',
    this.plan,
    this.accountType,
    this.offset = 0,
  });

  final String q, status;
  final String? plan, accountType;
  final int offset;

  /// Cualquier cambio de filtro vuelve a la primera página.
  UsersQuery filtro({
    String? q,
    String? status,
    Object? plan = _sin,
    Object? accountType = _sin,
  }) =>
      UsersQuery(
        q: q ?? this.q,
        status: status ?? this.status,
        plan: identical(plan, _sin) ? this.plan : plan as String?,
        accountType:
            identical(accountType, _sin) ? this.accountType : accountType as String?,
      );

  UsersQuery pagina(int offset) => UsersQuery(
        q: q,
        status: status,
        plan: plan,
        accountType: accountType,
        offset: offset,
      );
}

const Object _sin = Object();

final usersQueryProvider = StateProvider<UsersQuery>((ref) => const UsersQuery());

final usersPageProvider = FutureProvider.autoDispose<UsersResult>((ref) {
  final q = ref.watch(usersQueryProvider);
  return ref.watch(adminRepositoryProvider).users(
        q: q.q,
        status: q.status,
        plan: q.plan,
        accountType: q.accountType,
        limit: _pageSize,
        offset: q.offset,
      );
});

class UsersPage extends ConsumerStatefulWidget {
  const UsersPage({super.key});

  @override
  ConsumerState<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends ConsumerState<UsersPage> {
  late final TextEditingController _search;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(usersQueryProvider).q);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      ref.read(usersQueryProvider.notifier).update((s) => s.filtro(q: v));
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(usersQueryProvider);
    final page = ref.watch(usersPageProvider);
    final plans = ref.watch(plansProvider).valueOrNull ?? const <PlanItem>[];

    void set(UsersQuery Function(UsersQuery) f) =>
        ref.read(usersQueryProvider.notifier).update(f);

    return PageScaffold(
      title: 'Usuarios',
      subtitle: page.valueOrNull == null ? null : '${page.value!.total} cuentas',
      actions: [
        IconButton(
          tooltip: 'Actualizar',
          onPressed: () => ref.invalidate(usersPageProvider),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearch,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Buscar por nombre o correo',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                _Filtro<String>(
                  label: 'Estado',
                  value: query.status,
                  items: const {
                    'all': 'Todos',
                    'active': 'Activas',
                    'inactive': 'Desactivadas',
                    'deleted': 'Eliminadas',
                  },
                  onChanged: (v) => set((s) => s.filtro(status: v)),
                ),
                _Filtro<String?>(
                  label: 'Plan',
                  value: query.plan,
                  items: {
                    null: 'Todos',
                    for (final p in plans) p.code: p.name,
                  },
                  onChanged: (v) => set((s) => s.filtro(plan: v)),
                ),
                _Filtro<String?>(
                  label: 'Tipo',
                  value: query.accountType,
                  items: const {
                    null: 'Todos',
                    'family': 'Familiar',
                    'caregiver': 'Cuidadora',
                    'doctor': 'Médico',
                    'elder': 'Adulto mayor',
                  },
                  onChanged: (v) => set((s) => s.filtro(accountType: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AsyncBody<UsersResult>(
              value: page,
              onRetry: () => ref.invalidate(usersPageProvider),
              builder: (data) {
                if (data.items.isEmpty) {
                  return const EmptyView('No hay cuentas con esos filtros.',
                      icon: Icons.search_off);
                }
                return Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            showCheckboxColumn: false,
                            columns: const [
                              DataColumn(label: Text('Nombre')),
                              DataColumn(label: Text('Correo')),
                              DataColumn(label: Text('Tipo')),
                              DataColumn(label: Text('Plan')),
                              DataColumn(label: Text('Estado')),
                              DataColumn(label: Text('Alta')),
                            ],
                            rows: [
                              for (final u in data.items)
                                DataRow(
                                  onSelectChanged: (_) =>
                                      context.go('/usuarios/${u.userId}'),
                                  cells: [
                                    DataCell(Text(u.fullName +
                                        (u.isStaff ? ' (personal)' : ''))),
                                    DataCell(Text(u.email)),
                                    DataCell(Text(accountTypeLabel(u.accountType))),
                                    DataCell(StatusChip(u.planName,
                                        tone: u.planCode == 'free'
                                            ? Tone.neutral
                                            : Tone.good)),
                                    DataCell(StatusChip(userStatusLabel(u.status),
                                        tone: switch (u.status) {
                                          'active' => Tone.good,
                                          'inactive' => Tone.warn,
                                          _ => Tone.bad,
                                        })),
                                    DataCell(Text(fmtDate(u.createdAt))),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _Paginador(
                      data: data,
                      onPage: (o) => set((s) => s.pagina(o)),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Filtro<T> extends StatelessWidget {
  const _Filtro({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      child: DropdownButtonFormField<T>(
        key: ValueKey('$label-$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final e in items.entries)
            DropdownMenuItem<T>(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) => onChanged(v as T),
      ),
    );
  }
}

class _Paginador extends StatelessWidget {
  const _Paginador({required this.data, required this.onPage});
  final UsersResult data;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    final desde = data.offset + 1;
    final hasta = data.offset + data.items.length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text('$desde–$hasta de ${data.total}'),
          IconButton(
            tooltip: 'Anterior',
            onPressed: data.offset == 0
                ? null
                : () => onPage((data.offset - data.limit).clamp(0, data.total)),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Siguiente',
            onPressed: hasta >= data.total ? null : () => onPage(data.offset + data.limit),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

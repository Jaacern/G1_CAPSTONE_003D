import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/caregiver_providers.dart';
import '../data/caregiver_repository.dart';
import '../domain/models.dart';

/// Formulario para crear o editar una tarea del plan de cuidado.
class TaskEditScreen extends ConsumerStatefulWidget {
  const TaskEditScreen({super.key, required this.patientId, this.taskId});

  final String patientId;
  final String? taskId;

  @override
  ConsumerState<TaskEditScreen> createState() => _TaskEditScreenState();
}

class _TaskEditScreenState extends ConsumerState<TaskEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();

  final _categories = const [
    'Higiene',
    'Medicación',
    'Alimentación',
    'Actividad física',
    'Compañía',
    'Otros',
  ];
  String? _category;
  TimeOfDay? _time;
  TaskStatus _status = TaskStatus.pending;

  bool get _isEdit => widget.taskId != null;
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (_isEdit) _loadTask();
  }

  Future<void> _loadTask() async {
    if (!AppConfig.hasCaregiverLog) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final tasks =
          await ref.read(caregiverRepositoryProvider).listTasks(widget.patientId);
      final task = tasks.firstWhere((t) => t.id == widget.taskId);
      _title.text = task.title;
      _description.text = task.description ?? '';
      _category = task.category;
      _status = task.status;
      if (task.due != null) {
        _time = TimeOfDay(hour: task.due!.hour, minute: task.due!.minute);
      }
    } catch (_) {
      // Si no se encuentra, se comporta como creación.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  DateTime? _dueDateTime() {
    if (_time == null) return null;
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, _time!.hour, _time!.minute);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(caregiverRepositoryProvider);
    try {
      if (_isEdit) {
        // Los endpoints disponibles permiten actualizar el estado de la tarea.
        await repo.setTaskStatus(widget.taskId!, _status);
      } else {
        await repo.createTask(
          widget.patientId,
          NewCareTask(
            title: _title.text.trim(),
            description: _description.text.trim(),
            due: _dueDateTime(),
            category: _category,
          ),
        );
      }
      ref.invalidate(patientTasksProvider);
      ref.invalidate(caregiverTodayProvider);
      if (mounted) {
        showAppSnackBar(
            context, _isEdit ? 'Tarea actualizada.' : 'Tarea creada.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasCaregiverLog) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tarea')),
        body: const ComingSoonView(
          icon: Icons.checklist_rounded,
          title: 'Tareas de cuidado',
          subtitle: 'La bitácora de la cuidadora estará disponible pronto.',
        ),
      );
    }
    return Scaffold(
      appBar:
          AppBar(title: Text(_isEdit ? 'Editar tarea' : 'Nueva tarea')),
      body: _loading
          ? const LoadingView()
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  TextFormField(
                    controller: _title,
                    enabled: !_isEdit,
                    decoration: const InputDecoration(labelText: 'Título'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _description,
                    enabled: !_isEdit,
                    maxLines: 3,
                    decoration:
                        const InputDecoration(labelText: 'Descripción (opcional)'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _category,
                    decoration: const InputDecoration(labelText: 'Categoría'),
                    items: [
                      for (final c in _categories)
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged:
                        _isEdit ? null : (v) => setState(() => _category = v),
                  ),
                  const SizedBox(height: 12),
                  _TimeField(
                    time: _time,
                    enabled: !_isEdit,
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _time ?? TimeOfDay.now(),
                      );
                      if (picked != null) setState(() => _time = picked);
                    },
                  ),
                  if (_isEdit) ...[
                    const SizedBox(height: 20),
                    const Text('Estado',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final s in TaskStatus.values)
                          ChoiceChip(
                            label: Text(s.label),
                            selected: _status == s,
                            onSelected: (_) => setState(() => _status = s),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_rounded),
                    label: Text(_isEdit ? 'Guardar cambios' : 'Crear tarea'),
                  ),
                ],
              ),
            ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField(
      {required this.time, required this.onTap, this.enabled = true});

  final TimeOfDay? time;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(14),
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'Hora (opcional)'),
        child: Row(
          children: [
            const Icon(Icons.schedule_rounded,
                size: 20, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Text(
              time == null
                  ? 'Sin hora'
                  : time!.format(context),
              style: TextStyle(
                  color: time == null
                      ? AppColors.textSecondary
                      : AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

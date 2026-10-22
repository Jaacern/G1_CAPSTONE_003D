import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/caregiver_providers.dart';
import '../data/caregiver_repository.dart';
import '../domain/models.dart';

/// Formulario de nota de relevo + historial.
class HandoverScreen extends ConsumerStatefulWidget {
  const HandoverScreen({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<HandoverScreen> createState() => _HandoverScreenState();
}

class _HandoverScreenState extends ConsumerState<HandoverScreen> {
  final _text = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      showAppSnackBar(context, 'Escribe la nota de relevo.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(caregiverRepositoryProvider)
          .createHandoverNote(widget.patientId, text: text);
      _text.clear();
      ref.invalidate(handoverNotesProvider);
      if (mounted) {
        showAppSnackBar(context, 'Nota de relevo enviada.');
        FocusScope.of(context).unfocus();
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
        appBar: AppBar(title: const Text('Entrega de turno')),
        body: const ComingSoonView(
          icon: Icons.swap_horiz_rounded,
          title: 'Entrega de turno',
          subtitle: 'La bitácora de la cuidadora estará disponible pronto.',
        ),
      );
    }
    final async = ref.watch(handoverNotesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Nota de relevo')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _text,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Nota para el siguiente turno',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded),
                    label: const Text('Enviar relevo'),
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Historial',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const LoadingView(),
              error: (e, _) => ErrorView(
                message: e.toString(),
                onRetry: () => ref.invalidate(handoverNotesProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return const EmptyView(
                    icon: Icons.swap_horiz_rounded,
                    title: 'Sin notas de relevo',
                    subtitle: 'Aún no hay relevos registrados.',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _HandoverCard(note: items[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HandoverCard extends StatelessWidget {
  const _HandoverCard({required this.note});

  final HandoverNote note;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(name: note.authorName, radius: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(note.authorName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              Text(DateFormat('d MMM · HH:mm', 'es').format(note.createdAt),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 8),
          Text(note.text),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../patients/application/patients_providers.dart';
import '../application/caregiver_providers.dart';
import '../domain/models.dart';

/// Bitácora: observaciones y notas de relevo del paciente seleccionado.
class CaregiverLogScreen extends ConsumerWidget {
  const CaregiverLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);

    if (patient == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Bitácora')),
        body: const EmptyView(
          icon: Icons.person_off_rounded,
          title: 'Sin paciente seleccionado',
          subtitle: 'Selecciona un paciente para ver su bitácora.',
        ),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bitácora'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Observaciones'),
              Tab(text: 'Relevos'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ObservationsTab(patientId: patient.patientId),
            _HandoversTab(patientId: patient.patientId),
          ],
        ),
      ),
    );
  }
}

class _ObservationsTab extends ConsumerWidget {
  const _ObservationsTab({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(observationsProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: FilledButton.icon(
            onPressed: () => context.push('/cg/observation?patient=$patientId'),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nueva observación'),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
              message: e.toString(),
              onRetry: () => ref.invalidate(observationsProvider),
            ),
            data: (items) {
              if (items.isEmpty) {
                return const EmptyView(
                  icon: Icons.edit_note_rounded,
                  title: 'Sin observaciones',
                  subtitle: 'Registra la primera observación del turno.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(observationsProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _ObservationCard(obs: items[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ObservationCard extends StatelessWidget {
  const _ObservationCard({required this.obs});

  final Observation obs;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (obs.category != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(obs.category!,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.primary)),
                ),
                const Spacer(),
              ] else
                const Spacer(),
              Text(DateFormat('d MMM · HH:mm', 'es').format(obs.createdAt),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 8),
          Text(obs.text),
          if (obs.mediaUrl != null && obs.mediaUrl!.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(obs.mediaUrl!,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.person_rounded,
                  size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(obs.authorName,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }
}

class _HandoversTab extends ConsumerWidget {
  const _HandoversTab({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(handoverNotesProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: FilledButton.icon(
            onPressed: () => context.push('/cg/handover?patient=$patientId'),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nueva nota de relevo'),
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
                  subtitle: 'Deja una nota para el siguiente turno.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(handoverNotesProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _HandoverCard(note: items[i]),
                ),
              );
            },
          ),
        ),
      ],
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

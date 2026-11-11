import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/widgets/common.dart';
import '../../patients/application/patients_providers.dart';
import 'patient_documents_view.dart';

/// Expediente del paciente a pantalla completa (desde "Más" o el perfil del
/// paciente). Es la misma [PatientDocumentsView] que va embebida en la
/// ficha del médico y en Salud.
class DocumentsScreen extends ConsumerWidget {
  const DocumentsScreen({super.key, this.patientId});

  final String? patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!AppConfig.hasDocuments) {
      return Scaffold(
        appBar: AppBar(title: const Text('Expediente')),
        body: const ComingSoonView(
          icon: Icons.folder_shared_rounded,
          title: 'Expediente y documentos',
          subtitle: 'Pronto podrás guardar recetas, estudios y documentos '
              'del adulto mayor en un solo lugar.',
        ),
      );
    }

    // patient puede venir vacío ("/documents?patient="): se usa el elegido.
    final id = (patientId == null || patientId!.isEmpty)
        ? ref.watch(selectedPatientProvider)?.patientId
        : patientId;

    return Scaffold(
      appBar: AppBar(title: const Text('Expediente')),
      body: id == null
          ? const EmptyView(
              icon: Icons.person_search_rounded,
              title: 'Elige a un adulto mayor',
              subtitle: 'Elige a quién quieres ver el expediente.',
            )
          : PatientDocumentsView(key: ValueKey('docs-$id'), patientId: id),
    );
  }
}

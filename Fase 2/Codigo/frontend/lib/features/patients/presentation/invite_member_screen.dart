import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/domain/models.dart';
import '../application/patients_providers.dart';
import '../data/patients_repository.dart';
import '../domain/models.dart';

/// Invitar a un miembro del círculo de cuidado (ticket AGE-205).
///
/// El código es de UN adulto mayor: quien lo ingresa queda en el círculo de
/// ese paciente y de ningún otro. Si el familiar cuida a más de uno, elige
/// en la pantalla para cuál es; antes se usaba siempre el seleccionado en la
/// app, que casi siempre era el primero de la lista.
class InviteMemberScreen extends ConsumerStatefulWidget {
  const InviteMemberScreen({super.key});

  @override
  ConsumerState<InviteMemberScreen> createState() => _InviteMemberScreenState();
}

class _InviteMemberScreenState extends ConsumerState<InviteMemberScreen> {
  final _email = TextEditingController();
  RoleType _role = RoleType.caregiver;
  Invitation? _created;
  bool _loading = false;

  /// Adulto mayor elegido para el código. null = el que corresponde por
  /// defecto (ver [_porDefecto]).
  String? _patientId;

  /// Si no se eligió ninguno: el seleccionado en la app, si es de los que
  /// esta persona puede invitar; si no, el primero.
  PatientCard _porDefecto(List<PatientCard> propios) {
    final seleccionado = ref.read(selectedPatientProvider);
    return propios.firstWhere(
      (p) => p.patientId == seleccionado?.patientId,
      orElse: () => propios.first,
    );
  }

  Future<void> _submit(PatientCard patient) async {
    setState(() => _loading = true);
    try {
      final invitation = await ref.read(patientsRepositoryProvider).invite(
            patientId: patient.patientId,
            role: _role,
            email: _email.text.trim().isEmpty ? null : _email.text.trim(),
          );
      setState(() => _created = invitation);
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pacientes = ref.watch(myPatientsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Invitar al círculo de cuidado')),
      body: pacientes.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e.toString(),
          onRetry: () => ref.invalidate(myPatientsProvider),
        ),
        data: (lista) {
          // Solo un familiar invita (la API exige además que sea el
          // administrador del adulto mayor).
          final propios =
              lista.where((p) => p.role == RoleType.family).toList();
          if (propios.isEmpty) {
            return const EmptyView(
                icon: Icons.group_outlined,
                title: 'Primero agrega a tu adulto mayor',
                subtitle: 'Las invitaciones se envían por cada adulto mayor.');
          }
          final patient = propios.firstWhere(
            (p) => p.patientId == _patientId,
            orElse: () => _porDefecto(propios),
          );
          return _formulario(patient, propios);
        },
      ),
    );
  }

  Widget _formulario(PatientCard patient, List<PatientCard> propios) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (propios.length > 1) ...[
            DropdownButtonFormField<String>(
              initialValue: patient.patientId,
              decoration: const InputDecoration(
                labelText: '¿Para qué adulto mayor es el código?',
                prefixIcon: Icon(Icons.elderly_outlined),
              ),
              items: [
                for (final p in propios)
                  DropdownMenuItem(
                      value: p.patientId, child: Text(p.fullName)),
              ],
              // El código que estaba a la vista era del otro
              // adulto mayor: se esconde para no compartirlo por error.
              onChanged: (id) => setState(() {
                _patientId = id;
                _created = null;
              }),
            ),
            const SizedBox(height: 20),
          ],
          Text('Invitar a alguien al cuidado de ${patient.fullName}',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),
          const Text('¿Qué rol tendrá?',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<RoleType>(
            segments: const [
              ButtonSegment(
                  value: RoleType.caregiver,
                  label: Text('Cuidadora'),
                  icon: Icon(Icons.health_and_safety_outlined)),
              ButtonSegment(
                  value: RoleType.family,
                  label: Text('Familiar'),
                  icon: Icon(Icons.family_restroom_outlined)),
              ButtonSegment(
                  value: RoleType.doctor,
                  label: Text('Médico'),
                  icon: Icon(Icons.medical_services_outlined)),
              ButtonSegment(
                  value: RoleType.elder,
                  label: Text('Adulto mayor'),
                  icon: Icon(Icons.elderly_outlined)),
            ],
            selected: {_role},
            // Igual con el rol: el código de la vista era para otro.
            onSelectionChanged: (s) => setState(() {
              _role = s.first;
              _created = null;
            }),
            multiSelectionEnabled: false,
            showSelectedIcon: false,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Correo (opcional)',
              prefixIcon: Icon(Icons.mail_outline),
              helperText:
                  'Para identificar a quién invitaste. El código '
                  'se comparte aparte, por el medio que prefieras.',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _loading ? null : () => _submit(patient),
            child: const Text('Generar código'),
          ),
          if (_created != null) ...[
            const SizedBox(height: 24),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle,
                          color: AppColors.statusOk),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Código para '
                          '${_created!.role.label.toLowerCase()} · '
                          '${patient.fullName}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Center(
                    // 6 digitos grandes y espaciados: se leen de un
                    // vistazo y se pueden dictar por telefono.
                    child: SelectableText(
                      _created!.token,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 36,
                        letterSpacing: 8,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                        color: AppColors.primaryDark,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'Vence en 7 días · compártelo solo con esa persona.\n'
                      'La persona lo ingresa en Más → Unirme con un código.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: _created!.token));
                      if (context.mounted) {
                        showAppSnackBar(context, 'Código copiado');
                      }
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copiar código'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

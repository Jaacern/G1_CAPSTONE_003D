import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../../patients/application/patients_providers.dart';
import '../application/alerts_providers.dart';
import '../data/alerts_repository.dart';

/// Botón SOS autocontenido, reutilizable en Inicio y en la vista del adulto
/// mayor. Confirma, intenta obtener ubicación (best-effort) y envía la alerta.
///
/// El backend (9.6) solo autoriza a disparar SOS a la cuidadora y al adulto
/// mayor. Para el familiar/médico el botón no se muestra (coherente con el
/// wireframe: el familiar observa y escala desde el centro de alertas).
class SosButton extends ConsumerStatefulWidget {
  const SosButton({super.key});

  @override
  ConsumerState<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends ConsumerState<SosButton> {
  bool _sending = false;

  Future<void> _onPressed() async {
    // El adulto mayor no tiene selector: el paciente es él mismo, y sale de
    // su membresía. Leer el seleccionado lo dejaba en null en el primer toque
    // (nadie lo había elegido) y el SOS no salía.
    final user = ref.read(currentUserProvider);
    final propia = user?.primaryRole == RoleType.elder &&
            (user?.memberships.isNotEmpty ?? false)
        ? user!.memberships.first
        : null;
    final seleccionado = ref.read(selectedPatientProvider);
    final patientId = propia?.patientId ?? seleccionado?.patientId;
    final nombre = propia?.patientName ?? seleccionado?.fullName;
    if (patientId == null) {
      showAppSnackBar(
        context,
        'Elige a un adulto mayor antes de enviar un SOS.',
        error: true,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon:
            const Icon(Icons.sos_rounded, color: AppColors.critical, size: 40),
        title: const Text('¿Enviar alerta SOS?'),
        // Hoy el aviso es una alerta crítica que la red de cuidado ve en su
        // app; el envío push (RF-45) aún no está. No se promete más que eso.
        content: Text(
          propia != null
              ? 'Tu familia y tu cuidadora verán una alerta de emergencia en '
                  'su teléfono. Úsalo solo en una emergencia real.'
              : 'La red de cuidado de $nombre verá una alerta de emergencia. '
                  'Úsalo solo en una emergencia real.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.critical),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Enviar SOS'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _sending = true);
    try {
      final pos = await _tryGetLocation();
      await ref.read(alertsRepositoryProvider).sendSos(
            patientId,
            lat: pos?.latitude,
            lng: pos?.longitude,
          );
      ref.invalidate(alertsControllerProvider);
      if (!mounted) return;
      showAppSnackBar(
        context,
        pos != null
            ? 'Alerta de emergencia creada, con tu ubicación.'
            : 'Alerta de emergencia creada (sin ubicación).',
      );
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'No se pudo enviar el SOS.', error: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Intenta obtener la ubicación; ante cualquier problema devuelve null para
  /// que el SOS se envíe igualmente sin coordenadas.
  Future<Position?> _tryGetLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Solo cuidadora y adulto mayor pueden disparar SOS (roles del backend).
    final role = ref.watch(currentUserProvider)?.primaryRole;
    final canTriggerSos = role == RoleType.caregiver || role == RoleType.elder;
    if (!canTriggerSos) return const SizedBox.shrink();

    return FloatingActionButton.extended(
      onPressed: _sending ? null : _onPressed,
      backgroundColor: AppColors.critical,
      foregroundColor: Colors.white,
      icon: _sending
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.sos_rounded),
      label: Text(_sending ? 'Enviando...' : 'SOS'),
    );
  }
}

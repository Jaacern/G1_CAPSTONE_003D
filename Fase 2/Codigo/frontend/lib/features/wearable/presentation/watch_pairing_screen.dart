import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/watch_link_service.dart';

/// Pantalla para vincular un Reloj AgeCare a un paciente mediante un código de
/// un solo uso (RF-68).
///
/// Flujo que ve el usuario (cuidadora/familiar):
///   1. Toca "Generar código".
///   2. La app muestra 6 dígitos grandes + una cuenta regresiva.
///   3. Abre AgeCare en el reloj del paciente y escribe ese código.
///   4. La app DETECTA automáticamente que el reloj se vinculó (sondea el
///      estado cada pocos segundos) y muestra una pantalla de éxito.
///
/// El reloj no inicia sesión como una persona: se autentica como dispositivo
/// con el token que el backend le entrega al canjear el código.
class WatchPairingScreen extends ConsumerStatefulWidget {
  const WatchPairingScreen({
    super.key,
    required this.patientId,
    this.patientName,
  });

  final String patientId;
  final String? patientName;

  @override
  ConsumerState<WatchPairingScreen> createState() => _WatchPairingScreenState();
}

class _WatchPairingScreenState extends ConsumerState<WatchPairingScreen> {
  bool _loading = false;
  String? _error;
  WatchLinkCode? _code;
  Timer? _ticker;
  Timer? _poller;
  int _secondsLeft = 0;

  // Momento en que se generó el código: si el reloj reporta actividad después
  // de este instante, es que se vinculó con ESTE código (el "match").
  DateTime? _codeIssuedAt;
  bool _matched = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code =
          await ref.read(watchLinkServiceProvider).createLinkCode(widget.patientId);
      setState(() {
        _code = code;
        _secondsLeft = code.secondsLeft;
        _codeIssuedAt = DateTime.now().toUtc();
      });
      _startTicker();
      _startPolling();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No se pudo generar el código. Intenta de nuevo.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final left = _code?.secondsLeft ?? 0;
      setState(() => _secondsLeft = left);
      if (left <= 0) {
        _ticker?.cancel();
        _poller?.cancel(); // código vencido: deja de sondear.
      }
    });
  }

  /// Sondea el estado del reloj cada 3s. Cuando detecta que el dispositivo
  /// reportó actividad después de emitir el código, declara el match.
  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || _matched) return;
      try {
        final status =
            await ref.read(watchLinkServiceProvider).getStatus(widget.patientId);
        final seen = status.lastSeenAt?.toUtc();
        final issued = _codeIssuedAt;
        // Match: hay reloj vinculado y su última actividad es posterior (o casi)
        // al momento en que generamos el código.
        if (status.linked &&
            seen != null &&
            issued != null &&
            seen.isAfter(issued.subtract(const Duration(seconds: 5)))) {
          _onMatched();
        }
      } catch (_) {
        // Silencioso: un fallo de red no corta el sondeo.
      }
    });
  }

  void _onMatched() {
    if (_matched) return;
    setState(() => _matched = true);
    _ticker?.cancel();
    _poller?.cancel();
    // Refresca el estado del reloj en el resto de la app (p. ej. pantalla de
    // dispositivos) para que aparezca como vinculado.
    ref.invalidate(watchStatusProvider(widget.patientId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vincular reloj')),
      body: _matched ? _buildSuccess() : _buildPairing(),
    );
  }

  Widget _buildPairing() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _IntroCard(patientName: widget.patientName),
        const SizedBox(height: 16),
        if (_code == null) _buildGenerate() else _buildCode(_code!),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _error!),
        ],
        const SizedBox(height: 20),
        const _StepsCard(),
      ],
    );
  }

  Widget _buildGenerate() {
    return FilledButton.icon(
      onPressed: _loading ? null : _generate,
      icon: _loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.qr_code_2_rounded),
      label: Text(_loading ? 'Generando…' : 'Generar código'),
    );
  }

  Widget _buildCode(WatchLinkCode code) {
    final expired = _secondsLeft <= 0;
    return AppCard(
      child: Column(
        children: [
          const Text(
            'Escribe este código en el reloj',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final d in code.code.split(''))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _DigitBox(digit: d, dim: expired),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (expired)
            Column(
              children: [
                const Text(
                  'El código expiró.',
                  style: TextStyle(
                      color: AppColors.statusAttention,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _loading ? null : _generate,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Generar uno nuevo'),
                ),
              ],
            )
          else
            Column(
              children: [
                // Indicador de que la app está esperando al reloj.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Esperando al reloj…',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.timer_outlined,
                        size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      'Vence en ${_fmt(_secondsLeft)}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Solo "Copiar": mientras el código esté vigente, no hace falta
                // generar otro (sería redundante y crearía códigos de más).
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code.code));
                    showAppSnackBar(context, 'Código copiado.');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copiar código'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_rounded,
                size: 72, color: AppColors.statusOk),
            const SizedBox(height: 16),
            Text(
              widget.patientName != null
                  ? '¡Reloj de ${widget.patientName} vinculado!'
                  : '¡Reloj vinculado!',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            const Text(
              'El reloj ya está midiendo y enviando los signos vitales. '
              'Puedes verlos en la pantalla de Salud.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/home');
                }
              },
              child: const Text('Listo'),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

// --------------------------------------------------------------------------
class _DigitBox extends StatelessWidget {
  const _DigitBox({required this.digit, required this.dim});
  final String digit;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: (dim ? AppColors.textSecondary : AppColors.primary).withOpacity(.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (dim ? AppColors.textSecondary : AppColors.primary).withOpacity(.25),
        ),
      ),
      child: Text(
        digit,
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          color: dim ? AppColors.textSecondary : AppColors.primary,
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({this.patientName});
  final String? patientName;

  @override
  Widget build(BuildContext context) {
    final who = patientName != null ? ' de $patientName' : '';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Text('⌚', style: TextStyle(fontSize: 22)),
              SizedBox(width: 10),
              Expanded(
                child: Text('Reloj AgeCare',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Vincula el reloj$who para que mida en vivo su ritmo cardíaco, '
            'oxígeno en sangre y avise ante una caída. '
            'No necesita cuenta ni contraseña: se vincula con un código.',
            style: const TextStyle(
                color: AppColors.textSecondary, height: 1.4, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _StepsCard extends StatelessWidget {
  const _StepsCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text('Cómo vincular',
              style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(height: 10),
          _Step(n: '1', text: 'Toca "Generar código".'),
          _Step(n: '2', text: 'Abre la app AgeCare en el reloj del paciente.'),
          _Step(n: '3', text: 'Escribe los 6 dígitos en el reloj.'),
          _Step(n: '4', text: 'La app avisa sola cuando el reloj queda vinculado.'),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final String n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: AppColors.primary,
            child: Text(n,
                style: const TextStyle(
                    fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.statusAttention.withOpacity(.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 18, color: AppColors.statusAttention),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.statusAttention)),
          ),
        ],
      ),
    );
  }
}

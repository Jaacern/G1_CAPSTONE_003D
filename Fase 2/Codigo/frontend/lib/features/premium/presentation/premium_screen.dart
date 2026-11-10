import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../caregiver/application/caregiver_providers.dart';
import '../../caregiver/data/caregiver_repository.dart';
import '../../caregiver/domain/models.dart';

/// Paywall de AgeCare Premium para la cuidadora.
///
/// Integra `in_app_purchase`: consulta el producto configurado en las tiendas
/// (Google Play / App Store) y lanza la compra. Tras una compra exitosa se
/// llama a POST /caregiver/plan/upgrade para activar el plan en el backend.
///
/// Si la cuenta ya es Premium, la pantalla muestra hasta cuándo tiene acceso
/// y permite cancelar la renovación (POST /caregiver/plan/cancel). Cancelar no
/// corta el acceso: sigue hasta el fin del periodo ya pagado.
///
/// IMPORTANTE: para producción se requiere configurar el producto
/// [_kProductId] en Google Play Console y App Store Connect, además de los
/// permisos/entitlements de facturación en cada plataforma. En modo demo
/// (AppConfig.useMocks) o si la tienda no está disponible, la compra se
/// simula localmente para poder probar el flujo sin configuración de IAP.
class PremiumScreen extends ConsumerStatefulWidget {
  const PremiumScreen({super.key});

  @override
  ConsumerState<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends ConsumerState<PremiumScreen> {
  static const String _kProductId = 'agecare_premium_monthly';

  // in_app_purchase no tiene implementación web: tocar InAppPurchase.instance
  // en el navegador lanza LateInitializationError y deja la pantalla en rojo.
  // En web y en modo demo no hay tienda; la compra se simula.
  static const bool _hayTienda = !kIsWeb && !AppConfig.useMocks;
  final InAppPurchase? _iap = _hayTienda ? InAppPurchase.instance : null;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  bool _loading = true;
  bool _storeAvailable = false;
  bool _purchasing = false;
  bool _isPremium = false;
  bool _cancelling = false;
  String? _error;
  ProductDetails? _product;
  CaregiverPlan? _plan;

  @override
  void initState() {
    super.initState();
    _sub = _iap?.purchaseStream.listen(
      _onPurchaseUpdate,
      onError: (e) {
        if (mounted) setState(() => _error = e.toString());
      },
    );
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Primero se sabe qué plan tiene: si ya es Premium no se ofrece comprar.
      try {
        final plan = await ref.read(caregiverRepositoryProvider).getPlan();
        _plan = plan;
        _isPremium = plan.tier.isPremium;
      } catch (_) {
        // Sin plan conocido se muestra la oferta; el backend rechaza duplicados.
      }
      // En demo y en web no hay tienda.
      final iap = _iap;
      if (iap == null) {
        setState(() {
          _storeAvailable = false;
          _loading = false;
        });
        return;
      }
      final available = await iap.isAvailable();
      if (!available) {
        setState(() {
          _storeAvailable = false;
          _loading = false;
        });
        return;
      }
      final response = await iap.queryProductDetails({_kProductId});
      setState(() {
        _storeAvailable = true;
        _product = response.productDetails.isNotEmpty
            ? response.productDetails.first
            : null;
        if (_product == null) {
          _error =
              'El producto Premium no está disponible en la tienda todavía.';
        }
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        await _activateOnBackend();
        if (p.pendingCompletePurchase) {
          await _iap?.completePurchase(p);
        }
      } else if (p.status == PurchaseStatus.error) {
        if (mounted) {
          setState(() {
            _purchasing = false;
            _error = p.error?.message ?? 'La compra no se completó.';
          });
        }
      } else if (p.status == PurchaseStatus.canceled) {
        if (mounted) setState(() => _purchasing = false);
      }
    }
  }

  /// Activa el plan Premium en el backend tras una compra exitosa.
  Future<void> _activateOnBackend() async {
    try {
      final plan = await ref.read(caregiverRepositoryProvider).upgradePlan();
      ref.invalidate(caregiverPlanProvider);
      if (mounted) {
        setState(() {
          _plan = plan;
          _isPremium = plan.tier.isPremium;
          _purchasing = false;
        });
        showAppSnackBar(context, '¡Bienvenida a AgeCare Premium!');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _purchasing = false);
        showAppSnackBar(context, e.toString(), error: true);
      }
    }
  }

  Future<void> _subscribe() async {
    setState(() {
      _purchasing = true;
      _error = null;
    });

    // Demo / tienda no disponible: simulamos la compra y activamos el plan.
    final iap = _iap;
    if (iap == null || !_storeAvailable || _product == null) {
      await Future.delayed(const Duration(milliseconds: 700));
      await _activateOnBackend();
      return;
    }

    try {
      final param = PurchaseParam(productDetails: _product!);
      // Suscripción -> se trata como non-consumable en in_app_purchase.
      await iap.buyNonConsumable(purchaseParam: param);
      // El resultado llega por purchaseStream (_onPurchaseUpdate).
    } catch (e) {
      if (mounted) {
        setState(() {
          _purchasing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Precio en pantalla: el de la tienda si existe; si no, el del catálogo
  /// del backend. Nunca uno escrito a mano en la app.
  String get _priceLabel {
    if (_product != null) return _product!.price;
    final monto = _plan?.offerAmount;
    if (monto == null) return 'Premium';
    final entero = monto.round().toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'),
          (m) => '.',
        );
    return '\$$entero / mes';
  }

  String _fecha(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  Future<void> _cancelar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancelar suscripción'),
        content: Text(
          'No se renovará. Conservas Premium hasta '
          '${_plan?.validUntil == null ? 'el fin del periodo pagado' : _fecha(_plan!.validUntil!)}, '
          'y después tu cuenta pasa al plan gratuito. Puedes retomarla antes '
          'de esa fecha.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Mantener Premium')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancelar suscripción')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      final plan = await ref.read(caregiverRepositoryProvider).cancelPlan();
      ref.invalidate(caregiverPlanProvider);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _cancelling = false;
      });
      showAppSnackBar(context, 'Suscripción cancelada. No se renovará.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancelling = false);
      showAppSnackBar(context, e.toString(), error: true);
    }
  }

  /// Retoma la renovación de una suscripción cancelada que sigue vigente.
  /// El periodo ya está pagado, así que no se cobra de nuevo.
  Future<void> _reanudar() async {
    setState(() => _cancelling = true);
    try {
      final plan = await ref.read(caregiverRepositoryProvider).upgradePlan();
      ref.invalidate(caregiverPlanProvider);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _cancelling = false;
      });
      showAppSnackBar(context, 'Suscripción reanudada.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancelling = false);
      showAppSnackBar(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AgeCare Premium')),
      body: _loading
          ? const LoadingView()
          : _isPremium
              ? _AlreadyPremiumView(
                  plan: _plan,
                  busy: _cancelling,
                  fecha: _fecha,
                  onCancel: _cancelar,
                  onResume: _reanudar,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    _Hero(price: _priceLabel),
                    const SizedBox(height: 20),
                    Text('Todo lo que incluye',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    const _Benefit(
                      icon: Icons.smart_toy_outlined,
                      title: 'Asistente con IA',
                      subtitle:
                          'Hasta 200 consultas al mes sobre el expediente. '
                          'En el plan gratuito no está incluido.',
                    ),
                    const _Benefit(
                      icon: Icons.groups_rounded,
                      title: 'Pacientes y círculo sin tope',
                      subtitle:
                          'El plan gratuito permite 1 paciente y 3 miembros.',
                    ),
                    const _Benefit(
                      icon: Icons.history_rounded,
                      title: 'Historial completo',
                      subtitle:
                          'Sin límite de días. El plan gratuito guarda 30.',
                    ),
                    const _Benefit(
                      icon: Icons.folder_open_rounded,
                      title: 'Documentos, bitácora y reportes',
                      subtitle:
                          'Exámenes y recetas, observaciones del expediente e '
                          'informes de actividad. Hasta 5 GB de almacenamiento.',
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!,
                            style: const TextStyle(color: AppColors.critical)),
                      ),
                    if (!_storeAvailable && !AppConfig.useMocks)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'La tienda no está disponible en este dispositivo. '
                          'Se usará el modo de demostración.',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ),
                    FilledButton(
                      onPressed: _purchasing ? null : _subscribe,
                      child: _purchasing
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text('Suscribirme · $_priceLabel'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'La suscripción se renueva cada mes. Puedes cancelarla '
                      'cuando quieras desde esta pantalla: conservas Premium '
                      'hasta el fin del periodo pagado.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.price});
  final String price;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.workspace_premium_rounded,
              color: Colors.white, size: 40),
          const SizedBox(height: 12),
          const Text('AgeCare Premium',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text(
            'Más cupo, más historial y el asistente con IA para cuidar mejor.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          Text(price,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.primaryDark),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlreadyPremiumView extends StatelessWidget {
  const _AlreadyPremiumView({
    required this.plan,
    required this.busy,
    required this.fecha,
    required this.onCancel,
    required this.onResume,
  });

  final CaregiverPlan? plan;
  final bool busy;
  final String Function(DateTime) fecha;
  final VoidCallback onCancel;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final p = plan;
    final hasta = p?.validUntil;
    final cancelada = p?.cancelRequested ?? false;
    final cortesia = p?.isCourtesy ?? false;

    final String detalle;
    if (cancelada) {
      detalle = 'No se renovará. Conservas Premium hasta '
          '${hasta == null ? 'el fin del periodo' : fecha(hasta)}.';
    } else if (cortesia) {
      detalle = 'Tu Premium es una cortesía de AgeCare'
          '${hasta == null ? '.' : ' y vence el ${fecha(hasta)}.'}';
    } else {
      detalle = hasta == null
          ? 'Tu suscripción está activa.'
          : 'Se renueva el ${fecha(hasta)}.';
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.verified_rounded,
            size: 56, color: AppColors.primaryDark),
        const SizedBox(height: 12),
        const Text('Ya eres Premium',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(detalle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 28),
        if (cancelada)
          FilledButton(
            onPressed: busy ? null : onResume,
            child: busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Reanudar suscripción'),
          )
        else if (!cortesia)
          OutlinedButton(
            onPressed: busy ? null : onCancel,
            child: busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Cancelar suscripción'),
          ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';

/// Paywall de AgeCare Premium para la cuidadora.
///
/// Integra `in_app_purchase`: consulta el producto configurado en las tiendas
/// (Google Play / App Store) y lanza la compra. Tras una compra exitosa se
/// llama a POST /caregiver/plan/upgrade para activar el plan en el backend.
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

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  bool _loading = true;
  bool _storeAvailable = false;
  bool _purchasing = false;
  bool _isPremium = false;
  String? _error;
  ProductDetails? _product;

  @override
  void initState() {
    super.initState();
    _sub = _iap.purchaseStream.listen(
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
      // En modo demo no dependemos de la tienda.
      if (AppConfig.useMocks) {
        setState(() {
          _storeAvailable = false;
          _loading = false;
        });
        return;
      }
      final available = await _iap.isAvailable();
      if (!available) {
        setState(() {
          _storeAvailable = false;
          _loading = false;
        });
        return;
      }
      final response = await _iap.queryProductDetails({_kProductId});
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
          await _iap.completePurchase(p);
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
      await ref
          .read(apiClientProvider)
          .post<void>('/caregiver/plan/upgrade', data: {
        'plan': 'premium_monthly',
        'source': AppConfig.useMocks ? 'demo' : 'iap',
      });
      if (mounted) {
        setState(() {
          _isPremium = true;
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
    if (AppConfig.useMocks || !_storeAvailable || _product == null) {
      await Future.delayed(const Duration(milliseconds: 700));
      await _activateOnBackend();
      return;
    }

    try {
      final param = PurchaseParam(productDetails: _product!);
      // Suscripción -> se trata como non-consumable en in_app_purchase.
      await _iap.buyNonConsumable(purchaseParam: param);
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

  String get _priceLabel {
    if (_product != null) return _product!.price;
    return '\$149 / mes';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AgeCare Premium')),
      body: _loading
          ? const LoadingView()
          : _isPremium
              ? const _AlreadyPremiumView()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    _Hero(price: _priceLabel),
                    const SizedBox(height: 20),
                    Text('Todo lo que incluye',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    const _Benefit(
                      icon: Icons.insights_rounded,
                      title: 'Reportes avanzados',
                      subtitle:
                          'Tendencias de salud, adherencia y bienestar con más detalle.',
                    ),
                    const _Benefit(
                      icon: Icons.groups_rounded,
                      title: 'Más pacientes',
                      subtitle:
                          'Gestiona un número ilimitado de pacientes a tu cargo.',
                    ),
                    const _Benefit(
                      icon: Icons.workspace_premium_rounded,
                      title: 'Ofertas de trabajo premium',
                      subtitle:
                          'Acceso prioritario a las mejores ofertas del marketplace.',
                    ),
                    const _Benefit(
                      icon: Icons.support_agent_rounded,
                      title: 'Soporte prioritario',
                      subtitle: 'Atención preferente cuando la necesites.',
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
                      'La suscripción se renueva automáticamente. Puedes '
                      'cancelarla cuando quieras desde la tienda de tu '
                      'dispositivo.',
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
            'Potencia tu trabajo como cuidadora con herramientas profesionales.',
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
              color: AppColors.secondary.withOpacity(.18),
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
  const _AlreadyPremiumView();

  @override
  Widget build(BuildContext context) {
    return const EmptyView(
      icon: Icons.verified_rounded,
      title: 'Ya eres Premium',
      subtitle:
          'Disfruta de reportes avanzados, pacientes ilimitados y ofertas premium.',
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/notifications/push_service.dart';

/// Punto de entrada de AgeCare.
///
/// Ejecución típica:
///   flutter run --dart-define=USE_MOCKS=true                    (demo sin backend)
///   flutter run --dart-define=USE_MOCKS=false \
///               --dart-define=API_BASE_URL=https://api-dev.agecare.app \
///               --dart-define=SPIKE_APP_ID=1234                 (backend + Spike real)
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Formato de fechas en español (DateFormat(..., 'es') en toda la app).
  await initializeDateFormatting('es');

  // Notificaciones locales (alarmas de medicación) siempre disponibles.
  // El registro remoto (FCM -> Azure Notification Hubs) solo aplica sin mocks.
  await PushService.instance.init(enableRemote: !AppConfig.useMocks);

  runApp(const ProviderScope(child: AgeCareApp()));
}

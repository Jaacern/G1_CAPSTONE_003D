import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Design system de AgeCare: tokens de color, tipografía y tema Material 3.
/// Paleta pensada para transmitir calma (azules/verdes suaves) con
/// acentos claros para los estados del semáforo.
/// Tokens de color alineados con el wireframe HTML (paleta "refresh v2").
/// Se mantienen como `static const` para no romper los cientos de usos
/// `const` repartidos por la app. El modo oscuro se maneja con ThemeData.dark
/// + superficies específicas (ver AppTheme.dark()).
class AppColors {
  AppColors._();

  // Marca (HTML v2: --brand #3867e8, --brand-soft #eaf0ff).
  static const primary = Color(0xFF3867E8); // azul de marca del wireframe
  static const primaryDark = Color(0xFF2450C9); // variante oscura para texto
  static const brandSoft = Color(0xFFEAF0FF); // fondo suave de marca
  static const secondary = Color(0xFF7B8CF0); // acento lavanda/azul
  static const accent = Color(0xFFF5B400); // dorado del logo

  // Superficies e inks (HTML v2).
  static const background = Color(0xFFF1F5FA); // base del degradado de fondo
  static const surface = Colors.white;
  static const surfaceAlt = Color(0xFFF7F9FC); // --surface
  static const textPrimary = Color(0xFF182230); // --ink
  static const textSecondary = Color(0xFF667085); // --ink-soft
  static const textFaint = Color(0xFF98A2B3); // --ink-faint
  static const divider = Color(0xFFE7EBF2); // --line

  // Semáforo de bienestar (HTML v2).
  static const statusOk = Color(0xFF20A36A);
  static const statusWarning = Color(0xFFE29A22);
  static const statusAttention = Color(0xFFE04B43);

  // Alertas.
  static const critical = Color(0xFFE04B43);

  // Sombra suave de tarjeta (HTML v2: 0 18px 50px rgba(25,42,70,.14) atenuada).
  static const cardShadow = Color(0x141A2A46);

  // --- Superficies del modo oscuro (para ThemeData.dark) ---
  static const darkBackground = Color(0xFF0F141C);
  static const darkSurface = Color(0xFF18202B);
  static const darkDivider = Color(0xFF273240);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        surface: AppColors.surface,
      ),
      // Transparente: el fondo con degradado lo pinta AppBackground (app.dart).
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        // El AppBar es transparente, así que Flutter no puede deducir el
        // contraste de la barra de estado y usa íconos blancos sobre el fondo
        // claro. Se fija explícitamente.
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shadowColor: AppColors.cardShadow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.divider),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.primary.withOpacity(.12),
        // Fiel al wireframe: ítem activo en azul de marca, inactivos gris apagado.
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? AppColors.primary : AppColors.textSecondary,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.primary : AppColors.textSecondary,
          );
        }),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.divider, thickness: 1),
    );
  }

  /// Tema oscuro. Reusa el mismo azul de marca sobre superficies oscuras.
  /// Nota: los widgets que usan constantes claras de AppColors (textos/ iconos
  /// fijos) se verán igual; appbar, fondo, nav y tarjetas sí cambian. Un modo
  /// oscuro 100% requeriría migrar esos usos a Theme.of(context) (trabajo mayor).
  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.dark,
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        surface: AppColors.darkSurface,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.darkDivider),
        ),
        margin: EdgeInsets.zero,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.darkSurface,
        indicatorColor: AppColors.primary.withOpacity(.22),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? Colors.white : const Color(0xFF9AA6B5),
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF9AA6B5),
          );
        }),
      ),
      dividerTheme:
          const DividerThemeData(color: AppColors.darkDivider, thickness: 1),
    );
  }
}

/// Fondo con degradado azulado sutil, como el `body` del wireframe HTML
/// (radial azul arriba sobre una base clara). Se envuelve al MaterialApp para
/// que todas las pantallas lo compartan sin tocar cada Scaffold.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child, this.dark = false});

  final Widget child;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: dark
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF131A24), AppColors.darkBackground],
              )
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF8FAFF), AppColors.background],
              ),
      ),
      child: child,
    );
  }
}

/// Estado del semáforo de bienestar (alineado con la API: WellbeingStatus).
enum WellbeingStatus {
  ok('ok', 'Bien', AppColors.statusOk, Icons.check_circle_rounded),
  warning('warning', 'Regular', AppColors.statusWarning, Icons.error_rounded),
  attention('attention', 'Requiere atención', AppColors.statusAttention,
      Icons.warning_rounded);

  const WellbeingStatus(this.apiValue, this.label, this.color, this.icon);

  final String apiValue;
  final String label;
  final Color color;
  final IconData icon;

  static WellbeingStatus fromApi(String value) =>
      WellbeingStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => WellbeingStatus.ok,
      );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Design system de AgeCare — guía de marca v1.0.
///
/// Tokens de color, tipografía y forma alineados con la «Guía de diseño y
/// paleta de colores AgeCare». La paleta nace del pitch deck (marino, verde
/// azulado, coral, dorado) sobre un fondo crema cálido, con contraste WCAG 2.2
/// AA verificado y una sola familia tipográfica humanista: Nunito Sans.
///
/// La fuente de verdad de los tokens es [AgeColors]. La clase heredada
/// [AppColors] se conserva como alias para no romper los cientos de usos
/// `const` repartidos por la app; cada constante apunta al token AgeCare
/// equivalente, de modo que toda la interfaz adopta la nueva paleta sin tocar
/// cada pantalla.

/// Paleta AgeCare completa (anexo A de la guía). Nombres de token idénticos a
/// los usados en diseño y CSS: navy-800 -> navy800, teal-600 -> teal600, etc.
class AgeColors {
  AgeColors._();

  // --- Marino (confianza, texto, marca) ---
  static const navy900 = Color(0xFF0D1F33);
  static const navy800 = Color(0xFF12283F); // "negro" de AgeCare
  static const navy700 = Color(0xFF1B3A5A);
  static const navy500 = Color(0xFF3A5A7C);
  static const navy100 = Color(0xFFDCE4EE);

  // --- Verde azulado (acción) ---
  static const teal700 = Color(0xFF0A5453);
  static const teal600 = Color(0xFF0E7C7B); // acción principal
  static const teal500 = Color(0xFF1B9594);
  static const teal100 = Color(0xFFD9ECEB);
  static const teal50 = Color(0xFFEEF6F5);

  // --- Coral (calidez humana) ---
  static const coral700 = Color(0xFFB8482E); // único coral apto para texto
  static const coral600 = Color(0xFFD65F42);
  static const coral500 = Color(0xFFE8765A);
  static const coral100 = Color(0xFFFDEDE7);

  // --- Dorado (premium) ---
  static const gold700 = Color(0xFF8A6300);
  static const gold500 = Color(0xFFD9A300);
  static const gold100 = Color(0xFFF8EBBF);

  // --- Neutros cálidos (tiran a arena, nunca a azul) ---
  static const surfaceBg = Color(0xFFF7F4EE); // crema: fondo de pantalla
  static const surfaceCard = Color(0xFFFFFFFF); // tarjetas, campos
  static const surfaceSunken = Color(0xFFEFEAE1); // arena: hundidos, disabled
  static const border = Color(0xFFE3DED4);

  // --- Texto ---
  static const textPrimary = Color(0xFF12283F); // = navy-800
  static const textSecondary = Color(0xFF5B6573);
  static const textTertiary = Color(0xFF7C8794); // disabled / placeholders

  // --- Semánticos: estado "Bien" ---
  static const ok700 = Color(0xFF1F6B42);
  static const ok600 = Color(0xFF247A4A);
  static const ok100 = Color(0xFFE1F4E7);

  // --- Semánticos: estado "Regular" ---
  static const warn700 = Color(0xFF8F5800);
  static const warn500 = Color(0xFFE9A23B);
  static const warn100 = Color(0xFFFCEFD1);

  // --- Semánticos: estado "Atención" ---
  static const attention700 = Color(0xFF9E2A21);
  static const attention600 = Color(0xFFC8362B);
  static const attention100 = Color(0xFFFADCD8);

  // --- Semánticos: "Información" ---
  static const info700 = Color(0xFF245B95);
  static const info600 = Color(0xFF2F6FB3);
  static const info100 = Color(0xFFDDE9F7);

  // --- Sombras (la guía casi no usa; solo hojas, SOS y menús) ---
  static const shadowSheet = Color(0x2912283F); // 0 12 32 rgba(18,40,63,.16)
  static const shadowSos = Color(0x4DC8362B); // 0 6 16 rgba(200,54,43,.30)
  static const shadowMenu = Color(0x1A12283F); // 0 4 12 rgba(18,40,63,.10)

  // --- Modo oscuro (marino profundo, no negro) ---
  static const darkSurfaceBg = Color(0xFF0F1B2A);
  static const darkSurfaceCard = Color(0xFF182A40);
  static const darkBorder = Color(0xFF24405E);
  static const darkTextPrimary = Color(0xFFF2EEE6); // crema, no blanco puro
  static const darkTextSecondary = Color(0xFFB8C1CC);
  static const darkTeal = Color(0xFF3FB3B1);
  static const darkCoral = Color(0xFFF19A82);
  static const darkOk = Color(0xFF5CC08A);
  static const darkWarn = Color(0xFFF0B24A);
  static const darkAttention = Color(0xFFF0776B);
}

/// Acento fijo por rol (sección 4.5 de la guía). Se usa en avatares, etiquetas
/// de nombre y tarjetas de rol. Nunca para estados ni acciones.
class AgeRoleAccent {
  AgeRoleAccent._();

  /// Familiar: quien observa y decide. Coincide con el color de acción.
  static const familyFg = AgeColors.teal600;
  static const familyBg = AgeColors.teal100;

  /// Cuidadora: quien cuida y captura. El coral es el calor humano.
  static const caregiverFg = AgeColors.coral500;
  static const caregiverBg = AgeColors.coral100;

  /// Médico: participación acotada y formal.
  static const doctorFg = AgeColors.navy500;
  static const doctorBg = AgeColors.navy100;

  /// Adulto mayor: la persona en el centro.
  static const elderFg = AgeColors.gold500;
  static const elderBg = AgeColors.gold100;
}

/// Colores fijos de series en las gráficas de Salud (sección 9.1). Cada vital
/// tiene un color constante para que el familiar lo aprenda una vez.
class AgeChart {
  AgeChart._();

  static const heart = AgeColors.teal600; // ritmo cardíaco
  static const spo2 = AgeColors.navy500; // oxígeno (SpO2)
  static const activity = AgeColors.coral600; // actividad / pasos
  static const sleep = AgeColors.teal500; // sueño
  static const threshold = AgeColors.warn500; // umbral (línea discontinua)
  static const event = AgeColors.attention600; // eventos (caídas, dosis omit.)
}

/// Escala tipográfica AgeCare (sección 5.2). Alturas de línea absolutas.
class AgeText {
  AgeText._();

  static const display = TextStyle(
      fontSize: 34,
      height: 40 / 34,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.34);
  static const h1 =
      TextStyle(fontSize: 28, height: 34 / 28, fontWeight: FontWeight.w800);
  static const h2 =
      TextStyle(fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w700);
  static const h3 =
      TextStyle(fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w700);
  static const bodyL =
      TextStyle(fontSize: 18, height: 27 / 18, fontWeight: FontWeight.w400);
  static const body =
      TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w400);
  static const label =
      TextStyle(fontSize: 16, height: 20 / 16, fontWeight: FontWeight.w700);
  static const small =
      TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400);
  static const caption = TextStyle(
      fontSize: 12,
      height: 16 / 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8);
}

/// Radios de forma (sección 6.2).
class AgeRadius {
  AgeRadius._();
  static const double s = 8;
  static const double m = 12;
  static const double l = 14; // botones y campos
  static const double xl = 16; // tarjetas, banners
  static const double xxl = 24; // mosaicos, semáforo, diálogos
  static const double full = 999;
}

/// Espaciado sobre base 4 dp (sección 6.1).
class AgeSpace {
  AgeSpace._();
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s12 = 48;
}

/// Alias heredado. Cada miembro apunta al token AgeCare equivalente para que
/// toda la app adopte la nueva paleta sin cambiar cada `AppColors.x`.
class AppColors {
  AppColors._();

  // Marca: la acción principal pasa a verde azulado AgeCare.
  static const primary = AgeColors.teal600;
  static const primaryDark = AgeColors.teal700;
  static const brandSoft = AgeColors.teal100;
  static const secondary = AgeColors.coral500; // calidez (antes lavanda)
  static const accent = AgeColors.gold500; // dorado premium

  // Superficies e inks (neutros cálidos).
  static const background = AgeColors.surfaceBg; // crema
  static const surface = AgeColors.surfaceCard;
  static const surfaceAlt = AgeColors.surfaceBg;
  static const textPrimary = AgeColors.textPrimary;
  static const textSecondary = AgeColors.textSecondary;
  static const textFaint = AgeColors.textTertiary;
  static const divider = AgeColors.border;

  // Semáforo de bienestar.
  static const statusOk = AgeColors.ok600;
  static const statusWarning = AgeColors.warn500;
  static const statusAttention = AgeColors.attention600;

  // Alertas.
  static const critical = AgeColors.attention600;

  // Sombra suave de tarjeta (hojas/menús). La guía usa borde + superficie.
  static const cardShadow = AgeColors.shadowSheet;

  // --- Superficies del modo oscuro ---
  static const darkBackground = AgeColors.darkSurfaceBg;
  static const darkSurface = AgeColors.darkSurfaceCard;
  static const darkDivider = AgeColors.darkBorder;
}

class AppTheme {
  AppTheme._();

  static const _fontFamily = 'Nunito Sans';

  /// TextTheme con la escala AgeCare mapeada a los roles de Material 3.
  static TextTheme _textTheme(Color onSurface, Color onSurfaceVariant) {
    TextStyle t(TextStyle base, {Color? color}) =>
        base.copyWith(color: color ?? onSurface, fontFamily: _fontFamily);
    return TextTheme(
      displayLarge: t(AgeText.display),
      displayMedium: t(AgeText.display),
      displaySmall: t(AgeText.h1),
      headlineLarge: t(AgeText.h1),
      headlineMedium: t(AgeText.h2),
      headlineSmall: t(AgeText.h3),
      titleLarge: t(AgeText.h2),
      titleMedium: t(AgeText.h3),
      titleSmall: t(AgeText.label),
      bodyLarge: t(AgeText.bodyL),
      bodyMedium: t(AgeText.body),
      bodySmall: t(AgeText.small, color: onSurfaceVariant),
      labelLarge: t(AgeText.label),
      labelMedium: t(AgeText.small),
      labelSmall: t(AgeText.caption, color: onSurfaceVariant),
    );
  }

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: AgeColors.teal600,
        onPrimary: Colors.white,
        primaryContainer: AgeColors.teal100,
        onPrimaryContainer: AgeColors.teal700,
        secondary: AgeColors.coral500,
        onSecondary: AgeColors.navy800,
        secondaryContainer: AgeColors.coral100,
        onSecondaryContainer: AgeColors.coral700,
        tertiary: AgeColors.gold500,
        onTertiary: AgeColors.navy800,
        tertiaryContainer: AgeColors.gold100,
        onTertiaryContainer: AgeColors.gold700,
        error: AgeColors.attention600,
        onError: Colors.white,
        errorContainer: AgeColors.attention100,
        onErrorContainer: AgeColors.attention700,
        surface: AgeColors.surfaceCard,
        onSurface: AgeColors.textPrimary,
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: AgeColors.surfaceBg,
        surfaceContainer: AgeColors.surfaceBg,
        surfaceContainerHigh: AgeColors.surfaceSunken,
        surfaceContainerHighest: AgeColors.surfaceSunken,
        onSurfaceVariant: AgeColors.textSecondary,
        outline: AgeColors.border,
        outlineVariant: AgeColors.border,
      ),
      // Transparente: el fondo crema lo pinta AppBackground (app.dart).
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: _fontFamily,
    );

    return base.copyWith(
      textTheme: _textTheme(AgeColors.textPrimary, AgeColors.textSecondary),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: AgeColors.textPrimary,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          color: AgeColors.textPrimary,
          fontSize: 22,
          height: 28 / 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: AgeColors.surfaceCard,
        elevation: 0,
        shadowColor: AgeColors.shadowSheet,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AgeRadius.xl),
          side: const BorderSide(color: AgeColors.border),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AgeColors.teal600,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AgeColors.surfaceSunken,
          disabledForegroundColor: AgeColors.textTertiary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AgeRadius.l)),
          textStyle: AgeText.label.copyWith(fontFamily: _fontFamily),
        ),
      ),
      // Botón secundario: fondo blanco, borde marino, texto marino.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AgeColors.navy700,
          backgroundColor: AgeColors.surfaceCard,
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: AgeColors.navy700, width: 2),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AgeRadius.l)),
          textStyle: AgeText.label.copyWith(fontFamily: _fontFamily),
        ),
      ),
      // Botón terciario: texto en teal, sin fondo.
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AgeColors.teal600,
          textStyle: AgeText.label.copyWith(fontFamily: _fontFamily),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AgeColors.surfaceCard,
        labelStyle: const TextStyle(
            fontFamily: _fontFamily, color: AgeColors.textSecondary),
        hintStyle: const TextStyle(
            fontFamily: _fontFamily, color: AgeColors.textTertiary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AgeRadius.l),
          borderSide: const BorderSide(color: AgeColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AgeRadius.l),
          borderSide: const BorderSide(color: AgeColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AgeRadius.l),
          borderSide: const BorderSide(color: AgeColors.teal600, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AgeRadius.l),
          borderSide:
              const BorderSide(color: AgeColors.attention600, width: 1.6),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AgeRadius.l),
          borderSide:
              const BorderSide(color: AgeColors.attention600, width: 1.6),
        ),
        errorStyle: const TextStyle(
            fontFamily: _fontFamily, color: AgeColors.attention700),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AgeColors.surfaceCard,
        indicatorColor: AgeColors.teal100,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 28,
            color: selected ? AgeColors.teal700 : AgeColors.textSecondary,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: _fontFamily,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AgeColors.teal700 : AgeColors.textSecondary,
          );
        }),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: AgeColors.surfaceCard,
        selectedColor: AgeColors.teal100,
        side: BorderSide(color: AgeColors.border),
      ),
      dividerTheme:
          const DividerThemeData(color: AgeColors.border, thickness: 1),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AgeColors.navy800,
        contentTextStyle:
            TextStyle(fontFamily: _fontFamily, color: Colors.white),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Tema oscuro AgeCare (sección 4.6): marino profundo, acentos aclarados,
  /// texto crema. Sin sombras; la separación la da el color de superficie.
  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: AgeColors.darkTeal,
        onPrimary: AgeColors.darkSurfaceBg,
        primaryContainer: AgeColors.teal700,
        onPrimaryContainer: Colors.white,
        secondary: AgeColors.darkCoral,
        onSecondary: AgeColors.darkSurfaceBg,
        tertiary: AgeColors.gold500,
        onTertiary: AgeColors.darkSurfaceBg,
        error: AgeColors.darkAttention,
        onError: AgeColors.darkSurfaceBg,
        surface: AgeColors.darkSurfaceCard,
        onSurface: AgeColors.darkTextPrimary,
        onSurfaceVariant: AgeColors.darkTextSecondary,
        // Superficie hundida (chips, campos): el fondo de pantalla, un paso
        // mas oscuro que la tarjeta. En claro es surfaceSunken (arena).
        surfaceContainerHighest: AgeColors.darkSurfaceBg,
        outline: AgeColors.darkBorder,
        outlineVariant: AgeColors.darkBorder,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: _fontFamily,
    );

    return base.copyWith(
      textTheme:
          _textTheme(AgeColors.darkTextPrimary, AgeColors.darkTextSecondary),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: AgeColors.darkTextPrimary,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          color: AgeColors.darkTextPrimary,
          fontSize: 22,
          height: 28 / 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: AgeColors.darkSurfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AgeRadius.xl),
          side: const BorderSide(color: AgeColors.darkBorder),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AgeColors.darkTeal,
          foregroundColor: AgeColors.darkSurfaceBg,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AgeRadius.l)),
          textStyle: AgeText.label.copyWith(fontFamily: _fontFamily),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AgeColors.darkTextPrimary,
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: AgeColors.darkTextSecondary, width: 2),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AgeRadius.l)),
          textStyle: AgeText.label.copyWith(fontFamily: _fontFamily),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AgeColors.darkTeal,
          textStyle: AgeText.label.copyWith(fontFamily: _fontFamily),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AgeColors.darkSurfaceCard,
        indicatorColor: AgeColors.teal700,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 28,
            color: selected ? AgeColors.darkTeal : AgeColors.darkTextSecondary,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: _fontFamily,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AgeColors.darkTeal : AgeColors.darkTextSecondary,
          );
        }),
      ),
      dividerTheme:
          const DividerThemeData(color: AgeColors.darkBorder, thickness: 1),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AgeColors.darkSurfaceCard,
        contentTextStyle: TextStyle(
            fontFamily: _fontFamily, color: AgeColors.darkTextPrimary),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Fondo de pantalla AgeCare: crema plano (sin degradado azulado). Las tarjetas
/// blancas "flotan" sobre la crema por contraste de superficie, como pide la
/// guía. En oscuro, marino profundo.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child, this.dark = false});

  final Widget child;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: dark ? AgeColors.darkSurfaceBg : AgeColors.surfaceBg,
      child: child,
    );
  }
}

/// Estado del semáforo de bienestar (alineado con la API: WellbeingStatus).
/// Cada estado trae el trío de la guía: color fuerte (icono/punto/borde),
/// tinte (fondo de badge/banner) y texto (tono 700 sobre el tinte).
enum WellbeingStatus {
  ok('ok', 'Bien', AgeColors.ok600, AgeColors.ok100, AgeColors.ok700,
      Icons.check_circle_rounded),
  warning('warning', 'Regular', AgeColors.warn500, AgeColors.warn100,
      AgeColors.warn700, Icons.error_rounded),
  attention('attention', 'Requiere atención', AgeColors.attention600,
      AgeColors.attention100, AgeColors.attention700, Icons.warning_rounded);

  const WellbeingStatus(
      this.apiValue, this.label, this.color, this.tint, this.onTint, this.icon);

  final String apiValue;
  final String label;

  /// Color fuerte: icono, punto, borde.
  final Color color;

  /// Tinte: fondo de badge o banner.
  final Color tint;

  /// Texto sobre el tinte (tono 700 del estado).
  final Color onTint;
  final IconData icon;

  static WellbeingStatus fromApi(String value) =>
      WellbeingStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => WellbeingStatus.ok,
      );
}

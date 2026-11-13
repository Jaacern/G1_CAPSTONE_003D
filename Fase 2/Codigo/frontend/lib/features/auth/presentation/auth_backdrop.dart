import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Arte de marca: relleno cálido con dos círculos de color y el logo al centro.
///
/// El logo de AgeCare es azul índigo, lila y amarillo, con el nombre en azul
/// marino. Por eso el relleno es CLARO (coral y dorado suaves): el texto del
/// logo se lee bien y los círculos de color quedan en las esquinas, lejos del
/// nombre. Se usa dentro de la tarjeta del login y en la cabecera de la
/// bienvenida.
class BrandArt extends StatelessWidget {
  const BrandArt({
    super.key,
    required this.logoSize,
    this.logoAlignment = Alignment.center,
  });

  /// Alto del logo en píxeles lógicos.
  final double logoSize;

  /// Dónde cae el logo dentro del arte (la parte baja puede quedar tapada
  /// por el panel blanco que se superpone).
  final Alignment logoAlignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // Relleno base: coral muy suave que baja a dorado suave.
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AgeColors.coral100,
                      Color(0xFFFBE3D2),
                      AgeColors.gold100,
                    ],
                  ),
                ),
              ),
            ),
            // Círculo dorado, abajo a la izquierda, recortado por el borde.
            Positioned(
              left: -w * .16,
              bottom: -h * .30,
              child: _Blob(
                  diameter: h * .78,
                  color: AgeColors.gold500.withValues(alpha: .9)),
            ),
            // Círculo verde azulado, a la derecha, recortado por el borde.
            Positioned(
              right: -w * .14,
              bottom: -h * .08,
              child: _Blob(
                  diameter: h * .62,
                  color: AgeColors.teal500.withValues(alpha: .9)),
            ),
            // Círculo coral pequeño, arriba a la derecha.
            Positioned(
              right: w * .10,
              top: -h * .16,
              child: _Blob(
                  diameter: h * .42,
                  color: AgeColors.coral500.withValues(alpha: .9)),
            ),
            Align(
              alignment: logoAlignment,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Halo blanco: separa el logo de los círculos de color.
                  Container(
                    width: logoSize * 1.5,
                    height: logoSize * 1.2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Colors.white.withValues(alpha: .92),
                          Colors.white.withValues(alpha: .6),
                          Colors.white.withValues(alpha: 0),
                        ],
                        stops: const [0, .55, 1],
                      ),
                    ),
                  ),
                  Semantics(
                    label: 'AgeCare',
                    image: true,
                    child: Image.asset(
                      'assets/images/Agecare_logo.png',
                      height: logoSize,
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.diameter, required this.color});

  final double diameter;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }
}

/// Cabecera de la pantalla de bienvenida: el arte de marca cortado por una
/// ola con filo verde azulado.
class AuthHeader extends StatelessWidget {
  const AuthHeader({
    super.key,
    required this.height,
    required this.logoSize,
  });

  final double height;
  final double logoSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Filo de la ola: verde azulado de acción, un poco más abajo.
          ClipPath(
            clipper: _WaveClipper(drop: 10),
            child: const ColoredBox(color: AgeColors.teal600),
          ),
          ClipPath(
            clipper: _WaveClipper(),
            child: BrandArt(
              logoSize: logoSize,
              logoAlignment: const Alignment(0, -.2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ola inferior. [drop] baja la curva para dibujar la capa de borde.
class _WaveClipper extends CustomClipper<Path> {
  _WaveClipper({this.drop = 0});

  final double drop;

  @override
  Path getClip(Size s) {
    final w = s.width;
    final h = s.height - 14 + drop;
    return Path()
      ..lineTo(0, h * .80)
      ..cubicTo(w * .22, h * 1.0, w * .45, h * .68, w * .68, h * .86)
      ..cubicTo(w * .82, h * .94, w * .92, h * .88, w, h * .76)
      ..lineTo(w, 0)
      ..close();
  }

  @override
  bool shouldReclip(_WaveClipper old) => old.drop != drop;
}

/// Fondo de la pantalla de login: tono azul grisáceo muy suave con círculos
/// claros grandes, como detrás de la tarjeta.
class AuthPageBackground extends StatelessWidget {
  const AuthPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? AgeColors.darkSurfaceBg : AgeColors.navy100;
    final circle = dark
        ? AgeColors.darkSurfaceCard.withValues(alpha: .7)
        : Colors.white.withValues(alpha: .45);

    return ColoredBox(
      color: base,
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              right: -box.maxWidth * .25,
              top: -box.maxWidth * .10,
              child: _Blob(diameter: box.maxWidth * .75, color: circle),
            ),
            Positioned(
              left: -box.maxWidth * .30,
              bottom: -box.maxWidth * .15,
              child: _Blob(diameter: box.maxWidth * .85, color: circle),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }
}

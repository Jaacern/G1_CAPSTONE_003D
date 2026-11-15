import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Bloques de composicion de las pantallas.
///
/// Son las piezas que se repiten de una pantalla a otra: el encabezado de una
/// seccion, un acceso directo con su icono, un dato suelto y una fila de
/// lista con avatar. Viven juntos para que todas las pantallas se vean
/// iguales sin copiar y pegar medidas, que es como terminan apareciendo tres
/// radios distintos en la misma pantalla.

/// Titulo de seccion, con una accion opcional a la derecha.
class EncabezadoDeSeccion extends StatelessWidget {
  const EncabezadoDeSeccion(
    this.titulo, {
    super.key,
    this.accion,
    this.alPresionar,
  });

  final String titulo;

  /// Texto de la accion de la derecha, por ejemplo 'Ver todo'. Sin
  /// [alPresionar] no se dibuja: un enlace que no lleva a ninguna parte
  /// confunde mas de lo que adorna.
  final String? accion;
  final VoidCallback? alPresionar;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(titulo, style: AgeText.h3.copyWith(color: color)),
          ),
          if (accion != null && alPresionar != null)
            TextButton(
              onPressed: alPresionar,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(accion!, style: AgeText.small),
                  const Icon(Icons.chevron_right_rounded, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Acceso directo: un icono sobre un cuadrado de color y su etiqueta debajo.
///
/// El color va lleno y el icono en blanco, no al reves: a tamaño chico un
/// icono de color sobre fondo palido pierde contraste, y estos mosaicos son
/// de lo primero que se busca con la vista en la pantalla.
class MosaicoDeAcceso extends StatelessWidget {
  const MosaicoDeAcceso({
    super.key,
    required this.icono,
    required this.etiqueta,
    required this.color,
    this.alPresionar,
  });

  final IconData icono;
  final String etiqueta;
  final Color color;
  final VoidCallback? alPresionar;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: etiqueta,
      child: InkWell(
        onTap: alPresionar,
        borderRadius: BorderRadius.circular(AgeRadius.xl),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 60,
                width: 60,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AgeRadius.xl),
                ),
                child: Icon(icono, color: Colors.white, size: 28),
              ),
              const SizedBox(height: 8),
              // Sin ancho fijo: en una pantalla de 320 dp cuatro mosaicos con
              // ancho propio no entran, y el texto se recorta antes que la
              // fila se desborde.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  etiqueta,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AgeText.caption.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Un dato suelto con su etiqueta: 15 años, 3K pacientes, 2 alertas.
///
/// Pensada para ir de a tres en una fila. El valor manda y por eso va mas
/// grande que la etiqueta, que es lo que se lee despues para entenderlo.
class TarjetaDeDato extends StatelessWidget {
  const TarjetaDeDato({
    super.key,
    required this.valor,
    required this.etiqueta,
    this.color,
    this.alPresionar,
  });

  final String valor;
  final String etiqueta;

  /// Color del valor. Sirve para que un dato en rojo se note sin tener que
  /// escribir 'alerta' al lado.
  final Color? color;
  final VoidCallback? alPresionar;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: alPresionar,
      borderRadius: BorderRadius.circular(AgeRadius.xl),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: dark ? AgeColors.darkSurfaceCard : AgeColors.surfaceCard,
          borderRadius: BorderRadius.circular(AgeRadius.xl),
          border: Border.all(
              color: dark ? AgeColors.darkBorder : AgeColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              etiqueta,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AgeText.caption.copyWith(color: esquema.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text(
              valor,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AgeText.h3.copyWith(color: color ?? esquema.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// Etiqueta redondeada.
///
/// Sirve para dos cosas que se ven iguales. Sin [tono] enumera cosas cortas
/// sin jerarquia entre ellas: especialidades, idiomas, comunas. Con [tono]
/// dice un estado, y ahi el color es el mensaje: una toma pendiente en ambar
/// y una omitida en rojo se distinguen antes de que alguien lea la palabra.
///
/// No es un chip de filtro. Lo que se puede elegir y deselecionar son
/// ChoiceChip y FilterChip de Material, que ya traen su estado y su
/// semantica para el lector de pantalla; esto es solo una etiqueta.
class Etiqueta extends StatelessWidget {
  const Etiqueta(this.texto, {super.key, this.tono});

  final String texto;

  /// Color del texto y, al doce por ciento, del fondo.
  ///
  /// Va un tono oscuro de la paleta, de los que terminan en 700: el texto se
  /// dibuja con este mismo color y sobre su propio tinte un tono claro no
  /// alcanza el contraste que pide la guia.
  final Color? tono;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final tinte = tono;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: tinte == null
            ? esquema.surfaceContainerHighest
            : tinte.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(AgeRadius.full),
      ),
      child: Text(
        texto,
        style: AgeText.caption.copyWith(
          color: tinte ?? esquema.onSurface,
          fontWeight: tinte == null ? FontWeight.w400 : FontWeight.w700,
        ),
      ),
    );
  }
}

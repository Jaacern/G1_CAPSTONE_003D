import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';

/// Vista previa de un archivo recién elegido, antes de subirlo.
///
/// Image.file no sirve en el navegador. Ahí lo que entrega el selector no es
/// un archivo del disco sino un blob del navegador, y la ruta que trae no se
/// puede abrir. Leer los bytes sí funciona en las dos plataformas, así que la
/// vista previa se arma con Image.memory.
///
/// Los bytes se leen una sola vez y se guardan en el Future, para que
/// reconstruir el widget no vuelva a leer el archivo en cada cuadro.
class VistaPreviaArchivo extends StatefulWidget {
  const VistaPreviaArchivo(
    this.archivo, {
    super.key,
    this.height = 180,
    this.width,
    this.fit = BoxFit.cover,
  });

  final XFile archivo;
  final double height;
  final double? width;
  final BoxFit fit;

  @override
  State<VistaPreviaArchivo> createState() => _VistaPreviaArchivoState();
}

class _VistaPreviaArchivoState extends State<VistaPreviaArchivo> {
  late Future<Uint8List> _bytes = widget.archivo.readAsBytes();

  @override
  void didUpdateWidget(VistaPreviaArchivo anterior) {
    super.didUpdateWidget(anterior);
    if (anterior.archivo.path != widget.archivo.path) {
      _bytes = widget.archivo.readAsBytes();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snap) {
        if (snap.hasData) {
          return Image.memory(
            snap.data!,
            height: widget.height,
            width: widget.width,
            fit: widget.fit,
            // Si lo elegido no es una imagen (un PDF, por ejemplo) se muestra
            // el marcador en vez de dejar la pantalla con un error rojo.
            errorBuilder: (_, __, ___) => _marcador(context, Icons.description_rounded),
          );
        }
        if (snap.hasError) {
          return _marcador(context, Icons.broken_image_rounded);
        }
        return _marcador(context, null);
      },
    );
  }

  Widget _marcador(BuildContext context, IconData? icono) {
    return Container(
      height: widget.height,
      width: widget.width,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: icono == null
          ? const SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icono, size: 40, color: Theme.of(context).hintColor),
    );
  }
}

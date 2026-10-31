import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/upload_service.dart';

/// Muestra una imagen guardada en el backend.
///
/// Por qué existe: el file_url que queda guardado en una foto, un mensaje o
/// un documento apunta a la API y exige credencial. Image.network no manda
/// cabeceras, así que pasarle ese file_url directo da siempre un 401 y la
/// imagen nunca aparece.
///
/// Este widget pide primero un enlace firmado de 5 minutos
/// (GET /files/{id}/download) y recién después carga la imagen. El enlace no
/// se guarda en ningún lado: vence, y se vuelve a pedir la próxima vez que
/// haga falta mostrar la foto.
///
/// Si la URL no es de nuestra API (los datos de ejemplo de los repositorios,
/// o una imagen externa) se carga tal cual, sin pedir nada.
class RemoteFileImage extends ConsumerStatefulWidget {
  const RemoteFileImage(
    this.fileUrl, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  final String fileUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  ConsumerState<RemoteFileImage> createState() => _RemoteFileImageState();
}

class _RemoteFileImageState extends ConsumerState<RemoteFileImage> {
  late Future<String> _url;

  @override
  void initState() {
    super.initState();
    _url = ref.read(uploadServiceProvider).signedUrl(widget.fileUrl);
  }

  @override
  void didUpdateWidget(RemoteFileImage old) {
    super.didUpdateWidget(old);
    // Si la lista se recicla y el widget pasa a mostrar otra foto, hay que
    // pedir el enlace de la nueva.
    if (old.fileUrl != widget.fileUrl) {
      _url = ref.read(uploadServiceProvider).signedUrl(widget.fileUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contenido = FutureBuilder<String>(
      future: _url,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _marco(const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ));
        }
        if (snap.hasError || snap.data == null) {
          return _marco(const Center(
            child: Icon(Icons.broken_image_outlined, size: 28),
          ));
        }
        return Image.network(
          snap.data!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (_, __, ___) => _marco(
            const Center(child: Icon(Icons.broken_image_outlined, size: 28)),
          ),
        );
      },
    );

    if (widget.borderRadius == null) return contenido;
    return ClipRRect(borderRadius: widget.borderRadius!, child: contenido);
  }

  Widget _marco(Widget hijo) => Container(
        width: widget.width,
        height: widget.height,
        color: Colors.black12,
        child: hijo,
      );
}

/// Modelos del expediente de documentos del paciente.
library;

import 'package:flutter/material.dart' show IconData, Icons;

/// Categorías del expediente. La clave es la que viaja en la API
/// (documents.py la traduce al código de la base) y el orden es el de la
/// pantalla: primero lo que más se consulta para decidir.
enum DocumentCategory {
  receta('receta', 'Recetas', 'Receta', Icons.receipt_long_rounded),
  estudio('estudio', 'Exámenes de laboratorio', 'Examen de laboratorio',
      Icons.science_rounded),
  imagen('imagen', 'Imágenes', 'Imagen (radiografía, ecografía…)',
      Icons.image_search_rounded),
  informe('informe', 'Informes médicos', 'Informe médico',
      Icons.assignment_rounded),
  epicrisis('epicrisis', 'Epicrisis y altas', 'Epicrisis o alta',
      Icons.local_hospital_rounded),
  consentimiento('consentimiento', 'Consentimientos', 'Consentimiento',
      Icons.draw_rounded),
  prevision('prevision', 'Previsión y seguros', 'Previsión o seguro',
      Icons.health_and_safety_rounded),
  identificacion('identificacion', 'Identificación', 'Identificación',
      Icons.badge_rounded),
  general('general', 'Otros', 'Otro', Icons.description_rounded);

  const DocumentCategory(this.apiValue, this.plural, this.singular, this.icon);

  final String apiValue;

  /// Título del grupo y del filtro.
  final String plural;

  /// Etiqueta al elegir la categoría de un documento nuevo.
  final String singular;
  final IconData icon;

  static DocumentCategory fromApi(String? v) => DocumentCategory.values
      .firstWhere((c) => c.apiValue == v, orElse: () => DocumentCategory.general);
}

class PatientDocument {
  const PatientDocument({
    required this.id,
    required this.title,
    required this.category,
    required this.fileUrl,
    required this.createdAt,
    this.uploaderName,
  });

  final String id;
  final String title;

  /// Clave de la API (receta, estudio, imagen...). Ver [DocumentCategory].
  final String category;
  final String fileUrl;
  final DateTime createdAt;
  final String? uploaderName;

  DocumentCategory get categoria => DocumentCategory.fromApi(category);

  factory PatientDocument.fromJson(Map<String, dynamic> json) =>
      PatientDocument(
        id: json['id'] as String,
        title: (json['title'] ?? 'Documento') as String,
        category: (json['category'] ?? 'general') as String,
        fileUrl: json['file_url'] as String,
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : DateTime.now(),
        uploaderName: json['uploader_name'] as String?,
      );
}

/// Quita tildes y pasa a minúsculas, para buscar "radiografia" y encontrar
/// "Radiografía".
String normalizarBusqueda(String s) {
  const de = 'áàäâéèëêíìïîóòöôúùüûñ';
  const a = 'aaaaeeeeiiiioooouuuun';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().runes) {
    final c = String.fromCharCode(ch);
    final i = de.indexOf(c);
    b.write(i >= 0 ? a[i] : c);
  }
  return b.toString();
}

/// Documentos que calzan con el texto (título o quién lo subió) y la
/// categoría elegida (null = todas). Conserva el orden recibido.
List<PatientDocument> filtrarDocumentos(
  List<PatientDocument> docs, {
  String texto = '',
  DocumentCategory? categoria,
}) {
  final q = normalizarBusqueda(texto.trim());
  return [
    for (final d in docs)
      if ((categoria == null || d.categoria == categoria) &&
          (q.isEmpty ||
              normalizarBusqueda(d.title).contains(q) ||
              normalizarBusqueda(d.uploaderName ?? '').contains(q) ||
              normalizarBusqueda(d.categoria.plural).contains(q)))
        d,
  ];
}

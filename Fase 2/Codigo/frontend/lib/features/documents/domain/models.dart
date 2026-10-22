/// Modelos del expediente de documentos del paciente.

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
  final String category;
  final String fileUrl;
  final DateTime createdAt;
  final String? uploaderName;

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

/// Perfil profesional de la cuidadora (RF-72) y su publicación en el
/// marketplace (RF-75). Alineado con GET/PUT /caregiver/profile.
library;

enum ProfileStatus {
  draft('draft'),
  published('published'),
  suspended('suspended');

  const ProfileStatus(this.apiValue);
  final String apiValue;

  static ProfileStatus fromApi(String? v) => ProfileStatus.values
      .firstWhere((s) => s.apiValue == v, orElse: () => ProfileStatus.draft);
}

class ProfessionalProfile {
  const ProfessionalProfile({
    required this.firstName,
    this.secondName,
    required this.lastName,
    this.secondLastName,
    this.rut,
    this.phone,
    required this.email,
    this.headline = '',
    this.bio = '',
    this.yearsExperience = 0,
    this.hourlyRate,
    this.availability = 'part_time',
    this.acceptsOvernight = false,
    this.specialties = const [],
    this.languages = const [],
    this.zones = const [],
    this.certifications = const [],
    this.status = ProfileStatus.draft,
    this.missingForPublish = const [],
  });

  // Identidad
  final String firstName;
  final String? secondName;
  final String lastName;
  final String? secondLastName;
  final String? rut;
  final String? phone;
  final String email;

  // Profesional
  final String headline;
  final String bio;
  final int yearsExperience;

  /// Pesos por hora; null = a convenir.
  final int? hourlyRate;
  final String availability;
  final bool acceptsOvernight;

  /// Etiquetas del catálogo de especialidades.
  final List<String> specialties;

  /// Códigos ISO de dos letras.
  final List<String> languages;

  /// Códigos de comuna.
  final List<String> zones;

  /// Solo lectura: las verifica el equipo de AgeCare.
  final List<String> certifications;

  final ProfileStatus status;

  /// Lo que falta para poder publicar, en el texto que ve la cuidadora.
  final List<String> missingForPublish;

  bool get publicado => status == ProfileStatus.published;
  bool get suspendido => status == ProfileStatus.suspended;

  factory ProfessionalProfile.fromJson(Map<String, dynamic> j) =>
      ProfessionalProfile(
        firstName: (j['first_name'] ?? '') as String,
        secondName: j['second_name'] as String?,
        lastName: (j['last_name'] ?? '') as String,
        secondLastName: j['second_last_name'] as String?,
        rut: j['rut'] as String?,
        phone: j['phone'] as String?,
        email: (j['email'] ?? '') as String,
        headline: (j['headline'] ?? '') as String,
        bio: (j['bio'] ?? '') as String,
        yearsExperience: (j['years_experience'] ?? 0) as int,
        hourlyRate: j['hourly_rate'] as int?,
        availability: (j['availability'] ?? 'part_time') as String,
        acceptsOvernight: (j['accepts_overnight'] ?? false) as bool,
        specialties: _lista(j['specialties']),
        languages: _lista(j['languages']),
        zones: _lista(j['zones']),
        certifications: _lista(j['certifications']),
        status: ProfileStatus.fromApi(j['status'] as String?),
        missingForPublish: _lista(j['missing_for_publish']),
      );

  /// Cuerpo del PUT. [published] true publica, false retira, null no toca.
  Map<String, dynamic> toJson({bool? published}) => {
        'first_name': firstName,
        'second_name': secondName ?? '',
        'last_name': lastName,
        'second_last_name': secondLastName ?? '',
        if (rut != null && rut!.isNotEmpty) 'rut': rut,
        if (phone != null && phone!.isNotEmpty) 'phone': phone,
        'headline': headline,
        'bio': bio,
        'years_experience': yearsExperience,
        'hourly_rate': hourlyRate,
        'availability': availability,
        'accepts_overnight': acceptsOvernight,
        'specialties': specialties,
        'languages': languages,
        'zones': zones,
        if (published != null) 'published': published,
      };

  static List<String> _lista(Object? v) =>
      ((v ?? const []) as List).map((e) => e.toString()).toList();
}

class ProfileOption {
  const ProfileOption(this.code, this.label);
  final String code;
  final String label;

  factory ProfileOption.fromJson(Map<String, dynamic> j) =>
      ProfileOption(j['code'] as String, j['label'] as String);
}

/// Catálogos para elegir en vez de escribir (GET /caregiver/profile/options).
class ProfileOptions {
  const ProfileOptions({
    required this.specialties,
    required this.languages,
    required this.availability,
  });

  final List<ProfileOption> specialties;
  final List<ProfileOption> languages;
  final List<ProfileOption> availability;

  factory ProfileOptions.fromJson(Map<String, dynamic> j) => ProfileOptions(
        specialties: _opciones(j['specialties']),
        languages: _opciones(j['languages']),
        availability: _opciones(j['availability']),
      );

  static List<ProfileOption> _opciones(Object? v) => ((v ?? const []) as List)
      .map((e) => ProfileOption.fromJson(e as Map<String, dynamic>))
      .toList();
}

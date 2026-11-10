import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/professional_profile.dart';

/// Perfil profesional de la cuidadora: identidad, datos profesionales y
/// publicación en el marketplace.
abstract class ProfessionalProfileRepository {
  Future<ProfessionalProfile> get();
  Future<ProfileOptions> options();

  /// Guarda el perfil entero. [published] true publica (el servidor responde
  /// 422 PROFILE_INCOMPLETE si falta algo), false lo retira, null no lo toca.
  Future<ProfessionalProfile> save(ProfessionalProfile profile,
      {bool? published});
}

class ProfessionalProfileRepositoryHttp implements ProfessionalProfileRepository {
  ProfessionalProfileRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<ProfessionalProfile> get() async => ProfessionalProfile.fromJson(
      await _api.get<Map<String, dynamic>>('/caregiver/profile'));

  @override
  Future<ProfileOptions> options() async => ProfileOptions.fromJson(
      await _api.get<Map<String, dynamic>>('/caregiver/profile/options'));

  @override
  Future<ProfessionalProfile> save(ProfessionalProfile profile,
          {bool? published}) async =>
      ProfessionalProfile.fromJson(await _api.put<Map<String, dynamic>>(
        '/caregiver/profile',
        data: profile.toJson(published: published),
      ));
}

/// Versión en memoria para el modo de prueba, con las mismas reglas de
/// publicación que el servidor.
class ProfessionalProfileRepositoryMock
    implements ProfessionalProfileRepository {
  static const _opciones = ProfileOptions(
    specialties: [
      ProfileOption('alzheimer', 'Alzheimer y demencias'),
      ProfileOption('diabetes', 'Diabetes'),
      ProfileOption('movilidad_reducida', 'Movilidad reducida'),
      ProfileOption('cuidados_paliativos', 'Cuidados paliativos'),
      ProfileOption('postoperatorio', 'Postoperatorio'),
    ],
    languages: [
      ProfileOption('es', 'Español'),
      ProfileOption('en', 'Inglés'),
      ProfileOption('pt', 'Portugués'),
      ProfileOption('ht', 'Criollo haitiano'),
    ],
    availability: [
      ProfileOption('full_time', 'Jornada completa'),
      ProfileOption('part_time', 'Media jornada'),
      ProfileOption('hourly', 'Por horas'),
      ProfileOption('live_in', 'Puertas adentro'),
      ProfileOption('weekends', 'Fines de semana'),
    ],
  );

  ProfessionalProfile _perfil = const ProfessionalProfile(
    firstName: 'Rosa',
    lastName: 'Millán',
    secondLastName: 'Díaz',
    rut: '15.234.567-4',
    phone: '+56987654321',
    email: 'cuidadora@agecare.app',
    headline: 'Cuidadora con experiencia en demencias',
    bio: 'Acompaño a adultos mayores hace ocho años, en domicilio y residencia.',
    yearsExperience: 8,
    hourlyRate: 6500,
    availability: 'full_time',
    specialties: ['Alzheimer y demencias', 'Diabetes'],
    languages: ['es'],
    zones: ['08101', '08102'],
    certifications: ['Curso de cuidados geriátricos'],
  );

  static List<String> faltantes(ProfessionalProfile p) => [
        if (p.rut == null || p.rut!.isEmpty) 'Tu RUT',
        if (p.phone == null || p.phone!.isEmpty) 'Un teléfono de contacto',
        if (p.headline.trim().isEmpty) 'Un título para tu perfil',
        if (p.bio.trim().length < 40)
          'Una presentación de al menos 40 caracteres',
        if (p.specialties.isEmpty) 'Al menos una especialidad',
        if (p.zones.isEmpty) 'Al menos una comuna donde trabajas',
        if (p.languages.isEmpty) 'Al menos un idioma',
      ];

  ProfessionalProfile _conEstado(ProfessionalProfile p, ProfileStatus s) =>
      ProfessionalProfile(
        firstName: p.firstName,
        secondName: p.secondName,
        lastName: p.lastName,
        secondLastName: p.secondLastName,
        rut: p.rut,
        phone: p.phone,
        email: p.email,
        headline: p.headline,
        bio: p.bio,
        yearsExperience: p.yearsExperience,
        hourlyRate: p.hourlyRate,
        availability: p.availability,
        acceptsOvernight: p.acceptsOvernight,
        specialties: p.specialties,
        languages: p.languages,
        zones: p.zones,
        certifications: _perfil.certifications,
        status: s,
        missingForPublish: faltantes(p),
      );

  @override
  Future<ProfessionalProfile> get() async {
    await Future.delayed(const Duration(milliseconds: 250));
    return _conEstado(_perfil, _perfil.status);
  }

  @override
  Future<ProfileOptions> options() async => _opciones;

  @override
  Future<ProfessionalProfile> save(ProfessionalProfile profile,
      {bool? published}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    var estado = _perfil.status;
    if (published == true) {
      final falta = faltantes(profile);
      if (falta.isNotEmpty) {
        throw ApiException(
          statusCode: 422,
          code: 'PROFILE_INCOMPLETE',
          message: 'Para publicar tu perfil completa: '
              '${falta.join(', ').toLowerCase()}.',
        );
      }
      estado = ProfileStatus.published;
    } else if (published == false) {
      estado = ProfileStatus.draft;
    }
    _perfil = _conEstado(profile, estado);
    return _perfil;
  }
}

final professionalProfileRepositoryProvider =
    Provider<ProfessionalProfileRepository>((ref) {
  if (AppConfig.useMocks) return ProfessionalProfileRepositoryMock();
  return ProfessionalProfileRepositoryHttp(ref.watch(apiClientProvider));
});

final professionalProfileProvider =
    FutureProvider.autoDispose<ProfessionalProfile>(
        (ref) => ref.watch(professionalProfileRepositoryProvider).get());

final professionalProfileOptionsProvider = FutureProvider<ProfileOptions>(
    (ref) => ref.watch(professionalProfileRepositoryProvider).options());

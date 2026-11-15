/// Validadores de identidad del lado del cliente.
///
/// Repiten las reglas de `backend/api/app/validators.py` para avisar en el
/// formulario, antes de enviar. El backend vuelve a validar todo: estos son
/// una ayuda para la persona, no el control de seguridad.
library;

/// Nombre o apellido: letras (con tildes y ñ), espacios, apóstrofe, guion y
/// punto. Sin dígitos ni símbolos. Devuelve el mensaje de error o null.
String? validatePersonName(String? value,
    {String campo = 'el nombre', bool required = true}) {
  final v = (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  if (v.isEmpty) return required ? 'Escribe $campo' : null;
  if (v.length > 60) return 'Máximo 60 caracteres';
  if (!RegExp(r"^\p{L}[\p{L} '\-.]*$", unicode: true).hasMatch(v)) {
    return 'Solo letras, espacios, apóstrofe o guion';
  }
  return null;
}

/// Nombre de un alérgeno escrito a mano ("Otra"): empieza con letra; admite
/// letras, números, espacios y - . , ( ) / ' + (ej. "Vitamina B12",
/// "Kiwi", "Contraste yodado"). Mismas reglas que AllergyIn en el backend.
String? validateAllergenName(String? value) {
  final v = (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  if (v.isEmpty) return 'Escribe a qué es alérgico';
  if (v.length < 2) return 'Mínimo 2 caracteres';
  if (v.length > 80) return 'Máximo 80 caracteres';
  if (!RegExp(r"^\p{L}[\p{L}\p{N} '\-.,()/+]*$", unicode: true)
      .hasMatch(v)) {
    return 'Empieza con una letra; sin símbolos como < > # @';
  }
  if (RegExp(r'\p{L}', unicode: true).allMatches(v).length < 2) {
    return 'Escribe el nombre del alérgeno';
  }
  return null;
}

/// Dígito verificador de un RUT chileno (módulo 11).
String rutCheckDigit(int numero) {
  var suma = 0;
  var multiplo = 2;
  var n = numero;
  while (n > 0) {
    suma += (n % 10) * multiplo;
    multiplo = multiplo == 7 ? 2 : multiplo + 1;
    n ~/= 10;
  }
  final resto = 11 - (suma % 11);
  if (resto == 11) return '0';
  if (resto == 10) return 'K';
  return '$resto';
}

/// Valida un RUT escrito con o sin puntos y guion. Devuelve el error o null.
String? validateRut(String? value) {
  final limpio = (value ?? '').replaceAll(RegExp(r'[.\-\s]'), '').toUpperCase();
  if (limpio.isEmpty) return 'Escribe el RUT';
  if (!RegExp(r'^[0-9]{7,8}[0-9K]$').hasMatch(limpio)) {
    return 'Formato no válido (ej. 12.345.678-5)';
  }
  final numero = int.parse(limpio.substring(0, limpio.length - 1));
  if (numero < 1000000) return 'El RUT está fuera del rango válido';
  if (rutCheckDigit(numero) != limpio[limpio.length - 1]) {
    return 'El dígito verificador no corresponde';
  }
  return null;
}

/// RUT con puntos y guion (12.345.678-5). Si no se puede reconocer, lo
/// devuelve tal cual: la validación es la que avisa.
String formatRut(String value) {
  final limpio = value.replaceAll(RegExp(r'[.\-\s]'), '').toUpperCase();
  if (limpio.length < 2) return value;
  final cuerpo = limpio.substring(0, limpio.length - 1);
  final dv = limpio[limpio.length - 1];
  final conPuntos =
      cuerpo.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]}.');
  return '$conPuntos-$dv';
}

/// Teléfono chileno o internacional. Mismas reglas que el backend: 9 dígitos
/// sin prefijo (se asume +56) o con prefijo de país. Devuelve error o null.
String? validatePhone(String? value, {bool required = true}) {
  final s = (value ?? '').trim();
  if (s.isEmpty) return required ? 'Escribe el teléfono' : null;
  return normalizePhone(s) == null
      ? 'Debe tener 9 dígitos (ej. 9 1234 5678) o incluir el prefijo +56'
      : null;
}

/// E.164 (+56912345678) o null si no se reconoce.
String? normalizePhone(String value) {
  var s = value.trim().replaceAll(RegExp(r'[\s\-().]'), '');
  if (s.startsWith('00')) s = '+${s.substring(2)}';
  String digitos;
  if (s.startsWith('+')) {
    digitos = s.substring(1);
  } else if (s.length == 9) {
    digitos = '56$s';
  } else if (s.length == 11 && s.startsWith('56')) {
    digitos = s;
  } else {
    return null;
  }
  if (!RegExp(r'^[0-9]{8,15}$').hasMatch(digitos)) return null;
  return '+$digitos';
}

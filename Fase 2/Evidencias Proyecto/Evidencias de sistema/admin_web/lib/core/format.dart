String _dos(int n) => n.toString().padLeft(2, '0');

DateTime? parseDate(Object? v) =>
    v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

/// dd-MM-yyyy
String fmtDate(DateTime? d) =>
    d == null ? '—' : '${_dos(d.day)}-${_dos(d.month)}-${d.year}';

/// dd-MM-yyyy HH:mm
String fmtDateTime(DateTime? d) =>
    d == null ? '—' : '${fmtDate(d)} ${_dos(d.hour)}:${_dos(d.minute)}';

String fmtMoney(num? amount, [String? currency]) {
  if (amount == null) return '—';
  final esEntero = amount == amount.roundToDouble();
  final partes = (esEntero ? amount.toInt().toString() : amount.toStringAsFixed(2))
      .split('.');
  final miles = partes[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (m) => '.',
  );
  final txt = partes.length > 1 ? '$miles,${partes[1]}' : miles;
  return currency == null ? '\$$txt' : '\$$txt $currency';
}

const _tipos = {
  'family': 'Familiar',
  'caregiver': 'Cuidadora',
  'doctor': 'Médico',
  'elder': 'Adulto mayor',
};

String accountTypeLabel(String t) => _tipos[t] ?? t;

const _estados = {
  'active': 'Activa',
  'inactive': 'Desactivada',
  'deleted': 'Eliminada',
};

String userStatusLabel(String s) => _estados[s] ?? s;

const _acciones = {
  'plan_assigned': 'Plan asignado',
  'user_deactivated': 'Cuenta desactivada',
  'user_reactivated': 'Cuenta reactivada',
};

String auditActionLabel(String a) => _acciones[a] ?? a;

const _periodos = {
  'monthly': 'Mensual',
  'yearly': 'Anual',
  'once': 'Pago único',
};

String periodLabel(String p) => _periodos[p] ?? p;

const _estadosPlan = {
  'draft': 'Borrador',
  'active': 'Activo',
  'archived': 'Archivado',
};

String planStatusLabel(String s) => _estadosPlan[s] ?? s;

const _eventosPago = {
  'charge': 'Cobro',
  'renewal': 'Renovación',
  'refund': 'Reembolso',
  'chargeback': 'Contracargo',
  'payment_failed': 'Pago fallido',
  'plan_changed': 'Cambio de plan (personal)',
  'trial_started': 'Prueba iniciada',
  'cancelled': 'Cancelación',
  'expired': 'Vencimiento',
};

String billingTypeLabel(String t) => _eventosPago[t] ?? t;

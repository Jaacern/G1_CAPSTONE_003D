-- AgeCare — Ajuste de compatibilidad
-- 920_incidents_tipos.sql — Los tipos de incidente que la aplicacion ofrece
--
-- ck_incidents_type no cubre dos de los seis tipos que la pantalla de reporte
-- de incidentes ofrece en su lista: la reaccion adversa a un medicamento y la
-- emergencia medica. Las otras cuatro calzan (caida, fuga o desorientacion,
-- golpe o lesion, otro).
--
-- Mandarlas como 'other' seria perder justo la informacion que importa. Una
-- reaccion adversa apunta al medicamento y una emergencia medica es la que
-- hay que poder contar aparte cuando se revisa el historial del paciente.

ALTER TABLE incidents DROP CONSTRAINT IF EXISTS ck_incidents_type;

ALTER TABLE incidents ADD CONSTRAINT ck_incidents_type CHECK (
    type IN ('fall', 'wandering', 'aggression', 'refusal', 'injury',
             'choking', 'disorientation', 'adverse_reaction',
             'medical_emergency', 'other')
);

COMMENT ON COLUMN incidents.type IS
    'Tipo de incidente, lista cerrada. adverse_reaction es la reaccion adversa a un medicamento y medical_emergency la emergencia que requirio atencion externa.';

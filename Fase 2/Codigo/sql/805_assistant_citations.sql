CREATE TABLE assistant_citations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    query_id UUID NOT NULL REFERENCES assistant_queries(id) ON DELETE RESTRICT,
    source_table_name VARCHAR(100) NOT NULL,
    source_record_id UUID NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

COMMENT ON TABLE assistant_citations IS 'Citas y referencias a registros del expediente empleadas por el asistente de IA.';
COMMENT ON COLUMN assistant_citations.id IS 'Identificador único de la cita.';
COMMENT ON COLUMN assistant_citations.query_id IS 'Consulta del asistente a la que pertenece la cita.';
COMMENT ON COLUMN assistant_citations.source_table_name IS 'Nombre de la tabla fuente (ej: vital_readings).';
COMMENT ON COLUMN assistant_citations.source_record_id IS 'UUID del registro de origen citado.';
COMMENT ON COLUMN assistant_citations.created_at IS 'Fecha y hora de creación de la cita.';

CREATE INDEX ix_assistant_citations_source 
ON assistant_citations(source_table_name, source_record_id);
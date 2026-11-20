CREATE TABLE care_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
    assigned_to_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    title VARCHAR(150) NOT NULL,
    description TEXT,
    due_date DATE NOT NULL,
    due_time TIME,
    status VARCHAR(20) DEFAULT 'pending' NOT NULL,
    completed_at TIMESTAMP WITH TIME ZONE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_care_tasks_status CHECK (status IN ('pending', 'in_progress', 'completed', 'cancelled')),
    CONSTRAINT chk_care_tasks_completed CHECK (
        (status = 'completed' AND completed_at IS NOT NULL) OR
        (status <> 'completed' AND completed_at IS NULL)
    )
);

COMMENT ON TABLE care_tasks IS 'Listado de tareas de asistencia y rutinas diarias del círculo de cuidado.';
COMMENT ON COLUMN care_tasks.id IS 'Identificador único de la tarea de cuidado.';
COMMENT ON COLUMN care_tasks.patient_id IS 'Paciente receptor del cuidado.';
COMMENT ON COLUMN care_tasks.assigned_to_user_id IS 'Cuidador o familiar responsable de ejecutar la tarea.';
COMMENT ON COLUMN care_tasks.created_by_user_id IS 'Usuario que asignó la tarea (ej: familiar administrador).';
COMMENT ON COLUMN care_tasks.title IS 'Título o resumen de la tarea.';
COMMENT ON COLUMN care_tasks.description IS 'Detalles o instrucciones específicas para la tarea.';
COMMENT ON COLUMN care_tasks.due_date IS 'Fecha límite para realizar la tarea.';
COMMENT ON COLUMN care_tasks.due_time IS 'Hora específica sugerida para la tarea (opcional).';
COMMENT ON COLUMN care_tasks.status IS 'Estado actual de la tarea: pending, in_progress, completed, cancelled.';
COMMENT ON COLUMN care_tasks.completed_at IS 'Fecha y hora exacta en que se marcó como completada.';
COMMENT ON COLUMN care_tasks.deleted_at IS 'Fecha y hora de eliminación lógica.';
COMMENT ON COLUMN care_tasks.created_at IS 'Fecha y hora de creación de la tarea.';
COMMENT ON COLUMN care_tasks.updated_at IS 'Fecha y hora de última actualización.';

CREATE INDEX ix_care_tasks_assigned_due 
ON care_tasks(assigned_to_user_id, due_date ASC) WHERE deleted_at IS NULL;

CREATE TRIGGER tg_care_tasks_updated_at
BEFORE UPDATE ON care_tasks
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
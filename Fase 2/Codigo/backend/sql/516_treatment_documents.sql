-- AgeCare — Bloque 5: Bitácora y archivos
-- 516_treatment_documents.sql — Vínculo tratamiento ↔ receta formal (DEF-014)
--
-- Vive aquí (y no en 306_treatments.sql) porque referencia medical_documents,
-- que se crea en 515. La indicación (treatment_items) es la orden ejecutable;
-- la receta (medical_documents, category='prescription') es el documento
-- formal de respaldo. Esta tabla las relaciona sin confundirlas.

CREATE TABLE treatment_documents (
    treatment_id uuid        NOT NULL,
    document_id  uuid        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (treatment_id, document_id),

    CONSTRAINT fk_treatment_documents_treatment
        FOREIGN KEY (treatment_id) REFERENCES treatments(id) ON DELETE RESTRICT,
    CONSTRAINT fk_treatment_documents_document
        FOREIGN KEY (document_id) REFERENCES medical_documents(id) ON DELETE RESTRICT
);

COMMENT ON TABLE treatment_documents IS
    'Relaciona un tratamiento con la receta formal (medical_documents, category=prescription). La indicación es la orden ejecutable; la receta es el documento de respaldo. Son cosas distintas (DEF-014).';

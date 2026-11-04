-- AgeCare — Bloque 3: Medicación
-- 310_drug_catalog.sql — Catálogo de fármacos + validación de seguridad (Fase 6)
--
-- POR QUÉ (SEGURIDAD DEL PACIENTE, requisito crítico)
--   Un error de unidad o un número absurdo puede matar: loperamida en "kg",
--   bromuro de ipratropio en "100 ml", un comprimido de "10000 mg". La app NO
--   puede permitir esas combinaciones aunque alguien las seleccione o manipule
--   la petición. Ver docs/PLAN_IMPLEMENTACION_FICHA_CLINICA.md secciones 6 y 7.
--
--   Capas (todas en la BD, además de la UI):
--     1) drug_catalog: cada fármaco declara su principio activo, forma, vía,
--        unidad válida y su rango seguro de dosis por toma (min/max) y máximo
--        diario. El prescriptor NO teclea la unidad: se hereda del fármaco.
--     2) form_route_unit_rules: tabla de coherencia forma→vía→unidad. Un parche
--        es transdérmico; un aerosol inhalatorio; un comprimido oral. Combinación
--        incoherente = inválida.
--     3) Topes de cordura por unidad: última red (en el código del backend),
--        por si un fármaco libre no tiene rango cargado.
--
--   Fuente: estructura del Registro Sanitario del ISP (forma/concentración/vía
--   por producto) y nomenclatura de administración segura (los 5 correctos).
--   No hay API pública consultable del ISP; este catálogo es semilla.

-- ─────────────────────────────────────────────────────────────────
-- form_route_unit_rules — qué unidades y vías son válidas por forma
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE form_route_unit_rules (
    form   varchar(20) NOT NULL,   -- comprimido, capsula, jarabe, aerosol, parche...
    route  varchar(20) NOT NULL,   -- oral, inhalatoria, transdermica...
    unit   varchar(20) NOT NULL,   -- mg, mcg, ml, puff, parche...
    PRIMARY KEY (form, route, unit)
);

COMMENT ON TABLE form_route_unit_rules IS
    'Coherencia forma↔vía↔unidad. El backend rechaza un fármaco cuya combinación no exista aquí. Evita "parche vía oral" o "aerosol en ml".';

INSERT INTO form_route_unit_rules (form, route, unit) VALUES
    ('comprimido','oral','mg'),
    ('comprimido','oral','mcg'),
    ('comprimido','oral','g'),
    ('comprimido','sublingual','mg'),
    ('capsula','oral','mg'),
    ('capsula','oral','mcg'),
    ('jarabe','oral','ml'),
    ('jarabe','oral','mg'),
    ('gotas','oral','gotas'),
    ('gotas','oral','mg'),
    ('aerosol','inhalatoria','puff'),
    ('aerosol','inhalatoria','mcg'),
    ('inhalador','inhalatoria','puff'),
    ('inhalador','inhalatoria','mcg'),
    ('parche','transdermica','parche'),
    ('parche','transdermica','mcg'),
    ('ampolla','intramuscular','ml'),
    ('ampolla','intramuscular','mg'),
    ('ampolla','subcutanea','ml'),
    ('ampolla','subcutanea','UI'),
    ('ampolla','endovenosa','ml'),
    ('supositorio','rectal','mg'),
    ('crema','topica','g'),
    ('crema','topica','mg');


-- ─────────────────────────────────────────────────────────────────
-- drug_catalog — fármacos semilla con su presentación y rango seguro
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE drug_catalog (
    code              varchar(40)  PRIMARY KEY,
    active_ingredient varchar(100) NOT NULL,   -- principio activo
    label             varchar(120) NOT NULL,   -- nombre para mostrar
    form              varchar(20)  NOT NULL,
    route             varchar(20)  NOT NULL,
    unit              varchar(20)  NOT NULL,    -- unidad ÚNICA permitida
    dose_min          numeric(8,2) NOT NULL,    -- dosis mínima segura por toma
    dose_max          numeric(8,2) NOT NULL,    -- dosis máxima segura por toma
    max_daily         numeric(8,2),             -- máximo diario (opcional)

    CONSTRAINT fk_drug_catalog_rule
        FOREIGN KEY (form, route, unit)
        REFERENCES form_route_unit_rules (form, route, unit) ON DELETE RESTRICT,
    CONSTRAINT ck_drug_catalog_range
        CHECK (dose_min > 0 AND dose_max >= dose_min)
);

COMMENT ON TABLE drug_catalog IS
    'Catálogo semilla de fármacos. La unidad es ÚNICA por fármaco (no se teclea, se hereda). dose_min/dose_max acotan la dosis segura por toma; la FK a form_route_unit_rules garantiza coherencia forma↔vía↔unidad. Fuente: registro sanitario ISP (estructura) + caso real.';

-- Semilla: fármacos del caso real de Rosa + comunes en el adulto mayor.
INSERT INTO drug_catalog
    (code, active_ingredient, label, form, route, unit, dose_min, dose_max, max_daily) VALUES
    ('metformina',   'Metformina',            'Metformina 850 mg',       'comprimido','oral','mg',    250, 1000, 3000),
    ('losartan',     'Losartán',              'Losartán 50 mg',          'comprimido','oral','mg',    12.5, 100, 100),
    ('atorvastatina','Atorvastatina',         'Atorvastatina 20 mg',     'comprimido','oral','mg',    10,  80,  80),
    ('carvedilol',   'Carvedilol',            'Carvedilol 25 mg',        'comprimido','oral','mg',    3.125, 25, 50),
    ('levotiroxina', 'Levotiroxina',          'Levotiroxina 50 mcg',     'comprimido','oral','mcg',   25,  200, 300),
    ('digoxina',     'Digoxina',              'Digoxina 0,25 mg',        'comprimido','oral','mg',    0.0625, 0.25, 0.25),
    ('salmeterol',   'Salmeterol',            'Salmeterol aerosol',      'aerosol','inhalatoria','puff', 1, 2,  4),
    ('ipratropio',   'Bromuro de ipratropio', 'Bromuro de ipratropio',   'aerosol','inhalatoria','puff', 1, 2,  12),
    ('paracetamol',  'Paracetamol',           'Paracetamol 500 mg',      'comprimido','oral','mg',    500, 1000, 4000),
    ('aspirina',     'Ácido acetilsalicílico','Aspirina 100 mg',         'comprimido','oral','mg',    75,  500, 500),
    ('omeprazol',    'Omeprazol',             'Omeprazol 20 mg',         'capsula','oral','mg',       10,  40,  40),
    ('enalapril',    'Enalapril',             'Enalapril 10 mg',         'comprimido','oral','mg',    2.5, 40,  40),
    ('amlodipino',   'Amlodipino',            'Amlodipino 5 mg',         'comprimido','oral','mg',    2.5, 10,  10),
    ('furosemida',   'Furosemida',            'Furosemida 40 mg',        'comprimido','oral','mg',    20,  80,  160),
    ('loperamida',   'Loperamida',            'Loperamida 2 mg',         'comprimido','oral','mg',    2,   4,   16),
    ('insulina_nph', 'Insulina NPH',          'Insulina NPH',            'ampolla','subcutanea','UI', 2,   60,  100);

-- AgeCare — Marketplace
-- 928_job_offers.sql — Las ofertas de trabajo para cuidadoras
--
-- La pestana de empleos del marketplace lista ofertas con titulo, comuna,
-- pago y descripcion. No habia tabla: es la ultima pieza del marketplace que
-- faltaba en el esquema.
--
-- El pago se guarda como dos numeros y una unidad, no como el texto que la
-- pantalla muestra. La pantalla pide un campo 'pay' ya escrito, y armarlo
-- aca es trivial, pero al reves no: con un texto libre no se puede ordenar
-- por lo que pagan ni filtrar por un minimo, que es lo primero que va a
-- querer hacer alguien buscando trabajo. El texto se arma al responder.
--
-- Quien publica puede ser una familia buscando cuidadora o una institucion.
-- posted_by apunta al usuario que la creo y es obligatorio: una oferta sin
-- responsable no se le puede mostrar a nadie.

CREATE TABLE job_offers (
    id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),

    posted_by    uuid         NOT NULL,
    title        varchar(120) NOT NULL,
    description  varchar(2000) NOT NULL,

    -- Donde es el trabajo. El mismo codigo de comuna que caregiver_zones,
    -- para poder cruzar una oferta con las cuidadoras que atienden ahi.
    commune_code char(5)      NOT NULL,

    pay_min      numeric(12,2),
    pay_max      numeric(12,2),
    pay_period   varchar(10)  NOT NULL DEFAULT 'hour',
    currency     char(3)      NOT NULL DEFAULT 'CLP',

    schedule     varchar(120),
    starts_on    date,

    status       varchar(12)  NOT NULL DEFAULT 'draft',
    published_at timestamptz,
    closed_at    timestamptz,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    deleted_at   timestamptz,

    CONSTRAINT fk_job_offers_posted_by
        FOREIGN KEY (posted_by) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT ck_job_offers_title   CHECK (btrim(title) <> ''),
    CONSTRAINT ck_job_offers_desc    CHECK (btrim(description) <> ''),
    CONSTRAINT ck_job_offers_commune CHECK (commune_code ~ '^[0-9]{5}$'),
    CONSTRAINT ck_job_offers_currency CHECK (currency ~ '^[A-Z]{3}$'),

    CONSTRAINT ck_job_offers_pay_period CHECK (
        pay_period IN ('hour', 'day', 'month', 'shift')
    ),
    CONSTRAINT ck_job_offers_pay_positivo CHECK (
        (pay_min IS NULL OR pay_min >= 0) AND (pay_max IS NULL OR pay_max >= 0)
    ),
    -- Un rango al reves es un error de quien publica, no una oferta.
    CONSTRAINT ck_job_offers_pay_rango CHECK (
        pay_min IS NULL OR pay_max IS NULL OR pay_max >= pay_min
    ),

    CONSTRAINT ck_job_offers_status CHECK (
        status IN ('draft', 'published', 'closed')
    ),
    CONSTRAINT ck_job_offers_status_fecha CHECK (
        (status = 'draft'     AND published_at IS NULL AND closed_at IS NULL)
     OR (status = 'published' AND published_at IS NOT NULL AND closed_at IS NULL)
     OR (status = 'closed'    AND published_at IS NOT NULL AND closed_at IS NOT NULL)
    )
);

-- La pantalla pide las ofertas abiertas, lo mas nuevo primero.
CREATE INDEX ix_job_offers_abiertas
    ON job_offers (published_at DESC)
    WHERE status = 'published' AND deleted_at IS NULL;

-- Y cruzarlas por comuna con las cuidadoras que atienden ahi.
CREATE INDEX ix_job_offers_comuna
    ON job_offers (commune_code, published_at DESC)
    WHERE status = 'published' AND deleted_at IS NULL;

CREATE TRIGGER tg_job_offers_updated_at
    BEFORE UPDATE ON job_offers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE job_offers IS
    'Ofertas de trabajo para cuidadoras. El pago se guarda en numeros y no en texto para poder ordenar y filtrar por monto; el texto que muestra la pantalla se arma al responder.';
COMMENT ON COLUMN job_offers.commune_code IS
    'Comuna del trabajo, con el mismo codigo que caregiver_zones, para poder cruzar una oferta con quienes atienden ahi.';

INSERT INTO job_offers (posted_by, title, description, commune_code,
                        pay_min, pay_max, pay_period, schedule, status, published_at)
SELECT u.id, v.titulo, v.descripcion, v.comuna, v.minimo, v.maximo, v.periodo,
       v.horario, 'published', now() - make_interval(days => v.dias)
FROM (SELECT id FROM users WHERE is_active AND deleted_at IS NULL ORDER BY created_at LIMIT 1) u,
(VALUES
 ('Cuidadora para adulto mayor con movilidad reducida',
  'Se busca cuidadora con experiencia para acompanar a adulto mayor de 82 anios con movilidad reducida. Tareas: apoyo en traslados dentro de la casa, higiene, preparacion de almuerzo y recordar medicamentos. No requiere pernoctar.',
  '08101', 6000, 8000, 'hour', 'Lunes a viernes, 9 a 17 horas', 1),
 ('Acompanamiento de fin de semana',
  'Familia busca acompanamiento para su madre los sabados y domingos. Ella es autovalente, necesita compania, salir a caminar y conversar. Se valora paciencia y buen trato.',
  '08108', 55000, 70000, 'day', 'Sabado y domingo, 10 a 18 horas', 3),
 ('Turno de noche en domicilio',
  'Se requiere cuidadora para turno de noche con paciente postrado. Cambios de posicion cada tres horas, control de sonda y aviso ante cualquier cambio. Experiencia en pacientes postrados indispensable.',
  '08110', 45000, 60000, 'shift', 'Lunes, miercoles y viernes, 21 a 7 horas', 5),
 ('Cuidadora con experiencia en demencias',
  'Buscamos cuidadora con experiencia en Alzheimer para adulto mayor con deterioro cognitivo moderado. Se requiere manejo de episodios de desorientacion y rutinas estables. Jornada completa de lunes a viernes.',
  '08101', 750000, 900000, 'month', 'Lunes a viernes, jornada completa', 8),
 ('Apoyo por horas, tres veces por semana',
  'Se necesita apoyo por horas para bano asistido y preparacion de comidas. Tres veces por semana, horario a convenir en la manana.',
  '08102', 7000, NULL, 'hour', 'Tres manananas por semana, a convenir', 12)
) AS v(titulo, descripcion, comuna, minimo, maximo, periodo, horario, dias);

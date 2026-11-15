-- AgeCare - Esquema completo consolidado (modelo de datos al cierre)
-- Proyecto APT - Capstone PTY4614 - DUOC UC
-- PostgreSQL 16 - Modelo relacional normalizado hasta 3FN
--
-- Es el esquema que resulta de aplicar, en orden, las 131 migraciones de
-- Fase 2/Codigo/backend/sql sobre una base vacia (commit 22a6ec0).
-- 90 tablas, 3 de ellas particionadas por mes (148 contando las particiones),
-- 164 claves foraneas, 533 restricciones CHECK, 265 indices y 46 triggers.
--
-- Solo estructura: no trae datos ni las cuentas de demostracion.
-- GENERADO con pg_dump --schema-only. No editar a mano: el origen son las
-- migraciones numeradas.
-- ============================================================================

--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: analytics_events_block_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.analytics_events_block_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'analytics_events es inmutable: no se permite %', TG_OP;
END;
$$;


--
-- Name: audit_log_block_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_log_block_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'audit_log es inmutable: no se permite % ', TG_OP;
END;
$$;


--
-- Name: caregiver_reviews_refresh_rating(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.caregiver_reviews_refresh_rating() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    pid uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        pid := OLD.profile_id;
    ELSE
        pid := NEW.profile_id;
    END IF;

    UPDATE caregiver_profiles p
       SET rating_count = s.n,
           rating_avg   = CASE WHEN s.n = 0 THEN NULL ELSE round(s.prom, 2) END
      FROM (SELECT count(*) AS n, avg(rating) AS prom
              FROM caregiver_reviews
             WHERE profile_id = pid AND deleted_at IS NULL) s
     WHERE p.id = pid;

    RETURN NULL;
END;
$$;


--
-- Name: FUNCTION caregiver_reviews_refresh_rating(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.caregiver_reviews_refresh_rating() IS 'Recalcula rating_avg y rating_count del perfil a partir de sus reseñas vigentes.';


--
-- Name: ensure_vital_readings_partitions(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_vital_readings_partitions(months_ahead integer DEFAULT 3, months_back integer DEFAULT 0) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    m         int;
    base      date := date_trunc('month', now())::date;
    d_from    date;
    d_to      date;
    part_name text;
BEGIN
    FOR m IN -months_back..months_ahead LOOP
        d_from    := base + (m       || ' month')::interval;
        d_to      := base + ((m + 1) || ' month')::interval;
        part_name := format('vital_readings_%s', to_char(d_from, 'YYYY_MM'));

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF vital_readings
            FOR VALUES FROM (%L) TO (%L)',
            part_name,
            d_from::text || ' 00:00:00+00',
            d_to::text   || ' 00:00:00+00'
        );
    END LOOP;
END;
$$;


--
-- Name: FUNCTION ensure_vital_readings_partitions(months_ahead integer, months_back integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.ensure_vital_readings_partitions(months_ahead integer, months_back integer) IS 'Crea las particiones mensuales faltantes. En producción el worker la llama cada mes con months_ahead=3.';


--
-- Name: fn_purga_texto_ocr(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_purga_texto_ocr() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM file_ocr WHERE file_id = NEW.id;
    RETURN NEW;
END;
$$;


--
-- Name: FUNCTION fn_purga_texto_ocr(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fn_purga_texto_ocr() IS 'Borra el texto OCR (file_ocr) de un archivo cuando se purga su binario. Asi la depuracion del archivo no deja atras el contenido sensible extraido (RF-43).';


--
-- Name: notify_new_message(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_new_message() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Canal: 'chat_<conversation_id>'.
    -- Payload: JSON con los ids necesarios para que el backend identifique
    -- la conversación y al remitente sin consulta adicional.
    PERFORM pg_notify(
        'chat_new_message',
        json_build_object(
            'conversation_id', NEW.conversation_id,
            'message_id',      NEW.id,
            'sender_id',       NEW.sender_id,
            'kind',            NEW.kind,
            'created_at',      to_char(NEW.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')
        )::text
    );
    RETURN NEW;
END;
$$;


--
-- Name: FUNCTION notify_new_message(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.notify_new_message() IS 'Dispara un NOTIFY cuando se inserta un mensaje nuevo. El backend lo escucha y lo reenvía a los WebSockets conectados. RF-54.';


--
-- Name: rut_digito_verificador(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rut_digito_verificador(numero integer) RETURNS character
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    suma        integer := 0;
    multiplo    integer := 2;
    resto       integer;
    n           integer;
BEGIN
    IF numero IS NULL THEN
        RETURN NULL;
    END IF;

    n := numero;
    -- Se recorre de derecha a izquierda multiplicando por la serie 2,3,4,5,6,7
    -- y volviendo a empezar.
    WHILE n > 0 LOOP
        suma     := suma + (n % 10) * multiplo;
        multiplo := CASE WHEN multiplo = 7 THEN 2 ELSE multiplo + 1 END;
        n        := n / 10;
    END LOOP;

    resto := 11 - (suma % 11);
    RETURN CASE resto
             WHEN 11 THEN '0'
             WHEN 10 THEN 'K'
             ELSE resto::text
           END;
END;
$$;


--
-- Name: FUNCTION rut_digito_verificador(numero integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.rut_digito_verificador(numero integer) IS 'Calcula el dígito verificador de un RUT chileno por el módulo 11. IMMUTABLE: para el mismo número devuelve siempre lo mismo, que es lo que permite usarla dentro de un CHECK.';


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


--
-- Name: FUNCTION set_updated_at(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.set_updated_at() IS 'Trigger compartido: refresca updated_at en cada UPDATE. Se cuelga de toda tabla que tenga la columna; 916_triggers_updated_at.sql lo garantiza y falla si alguna queda sin él.';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    requested_by uuid NOT NULL,
    period_from date NOT NULL,
    period_to date NOT NULL,
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    doses_total integer,
    doses_taken integer,
    adherence_pct numeric(5,2),
    observations integer,
    incidents integer,
    tasks_done integer,
    storage_key character varying(300),
    mime_type character varying(100),
    size_bytes bigint,
    generated_at timestamp with time zone,
    failure_reason character varying(200),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_activity_reports_adherencia CHECK (((adherence_pct IS NULL) OR ((adherence_pct >= (0)::numeric) AND (adherence_pct <= (100)::numeric)))),
    CONSTRAINT ck_activity_reports_archivo CHECK ((((storage_key IS NULL) AND (mime_type IS NULL) AND (size_bytes IS NULL)) OR ((storage_key IS NOT NULL) AND (mime_type IS NOT NULL) AND (size_bytes IS NOT NULL)))),
    CONSTRAINT ck_activity_reports_ciclo CHECK (((((status)::text = 'pending'::text) AND (generated_at IS NULL) AND (storage_key IS NULL) AND (failure_reason IS NULL)) OR (((status)::text = 'ready'::text) AND (generated_at IS NOT NULL) AND (storage_key IS NOT NULL) AND (failure_reason IS NULL)) OR (((status)::text = 'failed'::text) AND (failure_reason IS NOT NULL) AND (storage_key IS NULL)))),
    CONSTRAINT ck_activity_reports_cifras CHECK ((((doses_total IS NULL) OR (doses_total >= 0)) AND ((doses_taken IS NULL) OR (doses_taken >= 0)) AND ((observations IS NULL) OR (observations >= 0)) AND ((incidents IS NULL) OR (incidents >= 0)) AND ((tasks_done IS NULL) OR (tasks_done >= 0)))),
    CONSTRAINT ck_activity_reports_dosis CHECK (((doses_total IS NULL) OR (doses_taken IS NULL) OR (doses_taken <= doses_total))),
    CONSTRAINT ck_activity_reports_mime CHECK (((mime_type IS NULL) OR ((mime_type)::text = ANY ((ARRAY['application/pdf'::character varying, 'text/csv'::character varying])::text[])))),
    CONSTRAINT ck_activity_reports_periodo CHECK ((period_to >= period_from)),
    CONSTRAINT ck_activity_reports_size CHECK (((size_bytes IS NULL) OR ((size_bytes >= 1) AND (size_bytes <= 26214400)))),
    CONSTRAINT ck_activity_reports_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'ready'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: TABLE activity_reports; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.activity_reports IS 'Reportes de actividad generados por rango de fechas. Conserva el documento emitido y el resumen congelado al momento de emitirlo, porque un reporte ya entregado no puede cambiar si los datos de origen se corrigen después. RF-74.';


--
-- Name: COLUMN activity_reports.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.id IS 'Identificador del reporte.';


--
-- Name: COLUMN activity_reports.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.patient_id IS 'Paciente sobre el que se emite el reporte.';


--
-- Name: COLUMN activity_reports.requested_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.requested_by IS 'Usuario que lo solicitó. Deja rastro de quién extrajo información del expediente.';


--
-- Name: COLUMN activity_reports.period_from; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.period_from IS 'Inicio del rango cubierto.';


--
-- Name: COLUMN activity_reports.period_to; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.period_to IS 'Fin del rango cubierto.';


--
-- Name: COLUMN activity_reports.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.status IS 'Estado de la generación: pending, ready o failed.';


--
-- Name: COLUMN activity_reports.doses_total; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.doses_total IS 'Tomas programadas en el período. Cifra congelada al emitir.';


--
-- Name: COLUMN activity_reports.doses_taken; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.doses_taken IS 'Tomas efectivamente administradas en el período.';


--
-- Name: COLUMN activity_reports.adherence_pct; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.adherence_pct IS 'Adherencia del período, de 0 a 100. Congelada al emitir.';


--
-- Name: COLUMN activity_reports.observations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.observations IS 'Cantidad de observaciones de bitácora del período.';


--
-- Name: COLUMN activity_reports.incidents; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.incidents IS 'Cantidad de incidentes del período.';


--
-- Name: COLUMN activity_reports.tasks_done; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.tasks_done IS 'Tareas de cuidado completadas en el período.';


--
-- Name: COLUMN activity_reports.storage_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.storage_key IS 'Ruta opaca del documento generado.';


--
-- Name: COLUMN activity_reports.mime_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.mime_type IS 'Formato del documento: PDF o CSV.';


--
-- Name: COLUMN activity_reports.size_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.size_bytes IS 'Tamaño del documento en bytes.';


--
-- Name: COLUMN activity_reports.generated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.generated_at IS 'Momento en que el documento quedó disponible.';


--
-- Name: COLUMN activity_reports.failure_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.failure_reason IS 'Motivo del fallo. Obligatorio cuando el estado es failed.';


--
-- Name: COLUMN activity_reports.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.created_at IS 'Fecha de creación del registro.';


--
-- Name: COLUMN activity_reports.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_reports.updated_at IS 'Fecha de la última modificación del registro.';


--
-- Name: activity_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    elder_device_id uuid,
    activity character varying(20) NOT NULL,
    started_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone,
    duration_seconds integer GENERATED ALWAYS AS ((EXTRACT(epoch FROM (ended_at - started_at)))::integer) STORED,
    interactions_count integer DEFAULT 0 NOT NULL,
    completed boolean DEFAULT false NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_activity_sessions_activity CHECK (((activity)::text = ANY ((ARRAY['gallery'::character varying, 'music'::character varying, 'reading'::character varying, 'listening'::character varying, 'chat'::character varying, 'checkin'::character varying, 'voice_message'::character varying, 'vitals'::character varying])::text[]))),
    CONSTRAINT ck_activity_sessions_completada CHECK (((NOT completed) OR (ended_at IS NOT NULL))),
    CONSTRAINT ck_activity_sessions_interactions CHECK ((interactions_count >= 0)),
    CONSTRAINT ck_activity_sessions_orden CHECK (((ended_at IS NULL) OR (ended_at >= started_at)))
);


--
-- Name: TABLE activity_sessions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.activity_sessions IS 'Sesiones de uso de las actividades del adulto mayor, con su duracion e interacciones. Base de las metricas de uso. RF-69.';


--
-- Name: COLUMN activity_sessions.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.id IS 'Identificador de la sesion.';


--
-- Name: COLUMN activity_sessions.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.patient_id IS 'Adulto mayor que uso la actividad.';


--
-- Name: COLUMN activity_sessions.elder_device_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.elder_device_id IS 'Dispositivo en que ocurrio la sesion. Nulo si fue desde otro cliente.';


--
-- Name: COLUMN activity_sessions.activity; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.activity IS 'Actividad utilizada. Lista cerrada.';


--
-- Name: COLUMN activity_sessions.started_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.started_at IS 'Inicio de la sesion.';


--
-- Name: COLUMN activity_sessions.ended_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.ended_at IS 'Fin de la sesion. Nulo mientras sigue abierta.';


--
-- Name: COLUMN activity_sessions.duration_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.duration_seconds IS 'Duracion en segundos. Columna generada a partir de started_at y ended_at.';


--
-- Name: COLUMN activity_sessions.interactions_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.interactions_count IS 'Cantidad de interacciones del adulto mayor durante la sesion.';


--
-- Name: COLUMN activity_sessions.completed; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.completed IS 'Si la actividad se llevo hasta el final.';


--
-- Name: COLUMN activity_sessions.meta; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.meta IS 'Datos propios de cada actividad, en formato libre.';


--
-- Name: COLUMN activity_sessions.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.activity_sessions.created_at IS 'Fecha de creacion del registro.';


--
-- Name: admin_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_id uuid NOT NULL,
    action character varying(40) NOT NULL,
    target_user_id uuid,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE admin_audit_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.admin_audit_log IS 'Acciones del personal sobre cuentas de usuario (cambio de plan, desactivacion, reactivacion). Solo se agrega; nada la modifica ni la borra.';


--
-- Name: COLUMN admin_audit_log.action; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.admin_audit_log.action IS 'plan_assigned | user_deactivated | user_reactivated.';


--
-- Name: COLUMN admin_audit_log.detail; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.admin_audit_log.detail IS 'Datos de la accion: motivo, plan anterior y nuevo, etc.';


--
-- Name: alert_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alert_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    alert_id uuid NOT NULL,
    user_id uuid NOT NULL,
    push_device_id uuid,
    channel character varying(10) DEFAULT 'push'::character varying NOT NULL,
    status character varying(10) DEFAULT 'queued'::character varying NOT NULL,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    opened_at timestamp with time zone,
    error_detail character varying(300),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    notice_round smallint DEFAULT 0 NOT NULL,
    CONSTRAINT ck_alert_deliveries_channel CHECK (((channel)::text = ANY ((ARRAY['push'::character varying, 'email'::character varying, 'sms'::character varying, 'in_app'::character varying])::text[]))),
    CONSTRAINT ck_alert_deliveries_failed CHECK ((((status)::text <> 'failed'::text) OR (error_detail IS NOT NULL))),
    CONSTRAINT ck_alert_deliveries_order CHECK ((((delivered_at IS NULL) OR (sent_at IS NULL) OR (delivered_at >= sent_at)) AND ((opened_at IS NULL) OR (delivered_at IS NULL) OR (opened_at >= delivered_at)))),
    CONSTRAINT ck_alert_deliveries_round CHECK ((notice_round >= 0)),
    CONSTRAINT ck_alert_deliveries_status CHECK (((status)::text = ANY ((ARRAY['queued'::character varying, 'sent'::character varying, 'delivered'::character varying, 'opened'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: TABLE alert_deliveries; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.alert_deliveries IS 'Una fila por cada intento de notificar a una persona sobre una alerta. No está en el Anexo A: se agrega porque sin ella los RNF-04 y RNF-05, que exigen latencias medibles, no se pueden comprobar.';


--
-- Name: COLUMN alert_deliveries.channel; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alert_deliveries.channel IS 'push es el canal principal. Los demás cubren el RF-82: vía alternativa cuando el push no se puede entregar.';


--
-- Name: COLUMN alert_deliveries.sent_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alert_deliveries.sent_at IS 'Momento en que el backend entregó la notificación al proveedor de push.';


--
-- Name: COLUMN alert_deliveries.delivered_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alert_deliveries.delivered_at IS 'Momento en que el proveedor confirmó la entrega al aparato. La diferencia con sent_at es la latencia que mide el RNF-05.';


--
-- Name: COLUMN alert_deliveries.opened_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alert_deliveries.opened_at IS 'Momento en que el usuario abrió la notificación. Distinto de delivered_at: llegar no es lo mismo que enterarse.';


--
-- Name: COLUMN alert_deliveries.notice_round; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alert_deliveries.notice_round IS 'Vuelta a la que pertenece la entrega: 0 = primer aviso, 1 = primer reaviso, y asi.';


--
-- Name: alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alerts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(20) NOT NULL,
    severity character varying(10) NOT NULL,
    title character varying(120) NOT NULL,
    detail text,
    payload jsonb,
    dedup_key character varying(60),
    status character varying(12) DEFAULT 'active'::character varying NOT NULL,
    acknowledged_by uuid,
    acknowledged_at timestamp with time zone,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    resolution_note character varying(500),
    escalated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    notified_at timestamp with time zone,
    renotify_count smallint DEFAULT 0 NOT NULL,
    dose_id uuid,
    reading_id uuid,
    CONSTRAINT ck_alerts_ack_pair CHECK (((acknowledged_at IS NULL) = (acknowledged_by IS NULL))),
    CONSTRAINT ck_alerts_escalated_after_notice CHECK (((renotify_count = 0) OR (notified_at IS NOT NULL))),
    CONSTRAINT ck_alerts_order CHECK (((resolved_at IS NULL) OR (acknowledged_at IS NULL) OR (resolved_at >= acknowledged_at))),
    CONSTRAINT ck_alerts_renotify_count CHECK ((renotify_count >= 0)),
    CONSTRAINT ck_alerts_resolved_pair CHECK (((resolved_at IS NULL) = (resolved_by IS NULL))),
    CONSTRAINT ck_alerts_severity CHECK (((severity)::text = ANY ((ARRAY['info'::character varying, 'warning'::character varying, 'critical'::character varying])::text[]))),
    CONSTRAINT ck_alerts_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'acknowledged'::character varying, 'resolved'::character varying])::text[]))),
    CONSTRAINT ck_alerts_status_ack CHECK ((((status)::text = 'active'::text) OR (acknowledged_at IS NOT NULL))),
    CONSTRAINT ck_alerts_status_resolved CHECK ((((status)::text <> 'resolved'::text) OR (resolved_at IS NOT NULL))),
    CONSTRAINT ck_alerts_type CHECK (((type)::text = ANY ((ARRAY['fall'::character varying, 'vital_out_of_range'::character varying, 'missed_dose'::character varying, 'sos'::character varying, 'wearable_offline'::character varying, 'incident'::character varying])::text[])))
);


--
-- Name: TABLE alerts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.alerts IS 'Alertas generadas por el sistema. Pilar central del producto: caída, vital fuera de rango, dosis no administrada, SOS y wearable sin datos.';


--
-- Name: COLUMN alerts.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.type IS 'Tipo de alerta. fall | vital_out_of_range | missed_dose | sos | wearable_offline | incident. ''incident'' la genera un incidente grave o critico reportado en la bitacora (DEF-003).';


--
-- Name: COLUMN alerts.payload; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.payload IS 'Detalle variable para MOSTRAR al abrir la alerta (valor, limites, nombre del farmaco, etc.), que cambia segun el tipo. Las referencias que el sistema cruza viven en columnas propias (dose_id, reading_id), no aqui. Excepcion a 1FN acotada a datos de solo presentacion.';


--
-- Name: COLUMN alerts.dedup_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.dedup_key IS 'Identifica la condición que originó la alerta (ej. spo2_low). Permite no repetir alertas por la misma causa dentro de 30 minutos (RF-46, AGE-501). La ventana de tiempo la evalúa el motor; la base aporta el índice.';


--
-- Name: COLUMN alerts.acknowledged_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.acknowledged_at IS 'Momento en que alguien atendió la alerta. NO está en el Anexo A: se agrega porque sin ella es imposible medir el tiempo de respuesta que exigen el ticket AGE-508 y el objetivo específico de Fase 1.';


--
-- Name: COLUMN alerts.escalated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.escalated_at IS 'Momento del ultimo reaviso por falta de atencion (RF-52). NULL = no hizo falta insistir. Los contactos no tienen orden (406): el reaviso va a todos.';


--
-- Name: COLUMN alerts.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.updated_at IS 'Última modificación. Columna renombrada de update_at (typo corregido): el trigger tg_alerts_updated_at la mantiene actualizada en cada UPDATE.';


--
-- Name: COLUMN alerts.notified_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.notified_at IS 'Momento en que se repartio el aviso de esta alerta (RF-45). NULL = todavia no se reparte. Lo escribe app/avisos.py.';


--
-- Name: COLUMN alerts.renotify_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.renotify_count IS 'Cuantas veces se volvio a avisar por falta de atencion (RF-52). Tiene techo en alert_renotify_max.';


--
-- Name: COLUMN alerts.dose_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.dose_id IS 'Dosis que origino la alerta (missed_dose, o incident por evento adverso). FK a scheduled_doses. Reemplaza al dose_id que vivia en payload. Unico por (dose_id, type): una alerta de cada tipo por dosis.';


--
-- Name: COLUMN alerts.reading_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.alerts.reading_id IS 'Lectura de signo vital que origino la alerta (vital_out_of_range). Sin FK: vital_readings tiene PK compuesta (id, measured_at) por ser particionada. Unico: una alerta por lectura.';


--
-- Name: allergen_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.allergen_catalog (
    code character varying(40) NOT NULL,
    label character varying(100) NOT NULL,
    category character varying(20) NOT NULL,
    active_ingredient character varying(100),
    CONSTRAINT ck_allergen_catalog_category CHECK (((category)::text = ANY ((ARRAY['medicamento'::character varying, 'alimento'::character varying, 'ambiental'::character varying, 'otra'::character varying])::text[])))
);


--
-- Name: TABLE allergen_catalog; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.allergen_catalog IS 'Catálogo semilla de alérgenos por categoría. Los de categoría medicamento llevan active_ingredient para cruzar con drug_catalog y advertir en la prescripción. El médico puede escribir un alérgeno libre (queda en otra).';


--
-- Name: analytics_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
)
PARTITION BY RANGE (occurred_at);


--
-- Name: TABLE analytics_events; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.analytics_events IS 'Flujo uniforme de hechos de la plataforma, particionado por mes e inmutable. Permite responder preguntas analíticas a dos o tres años sin unir las 41 tablas del modelo. Es la contraparte técnica de la política de no borrar nada.';


--
-- Name: COLUMN analytics_events.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.id IS 'Identificador del evento. La clave primaria es (id, occurred_at) porque la tabla está particionada por fecha.';


--
-- Name: COLUMN analytics_events.occurred_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.occurred_at IS 'Momento en que ocurrió el hecho. Es la clave de particionado.';


--
-- Name: COLUMN analytics_events.event_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.event_name IS 'Nombre del evento en minúsculas, con puntos para jerarquía (dose.taken, alert.acknowledged). Se valida el formato, no una lista cerrada: agregar una métrica no debe requerir migración.';


--
-- Name: COLUMN analytics_events.event_source; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.event_source IS 'De dónde vino: app (aplicación móvil), api, job (proceso automático), device (wearable o tablet), admin.';


--
-- Name: COLUMN analytics_events.actor_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.actor_type IS 'Clase de actor: user (persona con cuenta), elder (adulto mayor desde su dispositivo), system (proceso automático).';


--
-- Name: COLUMN analytics_events.actor_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.actor_user_id IS 'Usuario que originó el evento. Obligatorio cuando actor_type es user.';


--
-- Name: COLUMN analytics_events.actor_device_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.actor_device_id IS 'Dispositivo del adulto mayor que originó el evento. Obligatorio cuando actor_type es elder, porque el adulto mayor no tiene cuenta.';


--
-- Name: COLUMN analytics_events.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.patient_id IS 'Paciente al que se refiere el evento. Nulo en eventos de cuenta que no involucran a ningún paciente.';


--
-- Name: COLUMN analytics_events.entity_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.entity_type IS 'Tabla del registro al que se refiere el evento, por ejemplo scheduled_doses.';


--
-- Name: COLUMN analytics_events.entity_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.entity_id IS 'Identificador del registro en esa tabla. Permite volver al dato autoritativo.';


--
-- Name: COLUMN analytics_events.properties; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.properties IS 'Detalle propio del tipo de evento. jsonb INTENCIONAL: los tipos de evento son heterogéneos y abiertos; normalizarlos significaría una tabla por tipo. Mismo criterio que audit_log.old_value.';


--
-- Name: COLUMN analytics_events.request_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.analytics_events.request_id IS 'Identificador de la petición que generó el evento. Todos los eventos de una misma petición lo comparten, lo que permite reconstruir una acción completa.';


--
-- Name: analytics_events_202610; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202610 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202611; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202611 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202612; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202612 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202701; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202701 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202702; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202702 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202703; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202703 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202704; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202704 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202705; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202705 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202706; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202706 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202707; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202707 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202708; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202708 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202709; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202709 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202710; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202710 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202711; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202711 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_202712; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_202712 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: analytics_events_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events_default (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    event_name character varying(60) NOT NULL,
    event_source character varying(10) NOT NULL,
    actor_type character varying(10) NOT NULL,
    actor_user_id uuid,
    actor_device_id uuid,
    patient_id uuid,
    entity_type character varying(40),
    entity_id uuid,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_id uuid,
    CONSTRAINT ck_analytics_events_actor CHECK (((((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND (actor_device_id IS NULL)) OR (((actor_type)::text = 'elder'::text) AND (actor_device_id IS NOT NULL) AND (actor_user_id IS NULL)) OR (((actor_type)::text = 'system'::text) AND (actor_user_id IS NULL) AND (actor_device_id IS NULL)))),
    CONSTRAINT ck_analytics_events_actor_type CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'elder'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT ck_analytics_events_entity CHECK (((entity_type IS NULL) = (entity_id IS NULL))),
    CONSTRAINT ck_analytics_events_name CHECK ((((event_name)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'::text) AND (char_length((event_name)::text) >= 3))),
    CONSTRAINT ck_analytics_events_properties CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT ck_analytics_events_source CHECK (((event_source)::text = ANY ((ARRAY['app'::character varying, 'api'::character varying, 'job'::character varying, 'device'::character varying, 'admin'::character varying])::text[])))
);


--
-- Name: assistant_citations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assistant_citations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    query_id uuid NOT NULL,
    source_table_name character varying(100) NOT NULL,
    source_record_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: TABLE assistant_citations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.assistant_citations IS 'Citas y referencias a registros del expediente empleadas por el asistente de IA.';


--
-- Name: COLUMN assistant_citations.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_citations.id IS 'Identificador único de la cita.';


--
-- Name: COLUMN assistant_citations.query_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_citations.query_id IS 'Consulta del asistente a la que pertenece la cita.';


--
-- Name: COLUMN assistant_citations.source_table_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_citations.source_table_name IS 'Nombre de la tabla fuente (ej: vital_readings).';


--
-- Name: COLUMN assistant_citations.source_record_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_citations.source_record_id IS 'UUID del registro de origen citado.';


--
-- Name: COLUMN assistant_citations.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_citations.created_at IS 'Fecha y hora de creación de la cita.';


--
-- Name: assistant_queries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assistant_queries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    conversation_id uuid NOT NULL,
    conversation_type character varying(20) NOT NULL,
    user_id uuid NOT NULL,
    frozen_role_name character varying(50) NOT NULL,
    query_text text NOT NULL,
    response_text text NOT NULL,
    latency_ms integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_assistant_queries_frozen_role CHECK (((frozen_role_name)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT chk_assistant_queries_latency CHECK ((latency_ms >= 0)),
    CONSTRAINT chk_assistant_queries_tipo CHECK (((conversation_type)::text = ANY ((ARRAY['human'::character varying, 'assistant'::character varying])::text[])))
);


--
-- Name: TABLE assistant_queries; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.assistant_queries IS 'Registro de consultas realizadas al asistente de IA y sus respuestas.';


--
-- Name: COLUMN assistant_queries.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.id IS 'Identificador único de la consulta al asistente.';


--
-- Name: COLUMN assistant_queries.conversation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.conversation_id IS 'Conversación asociada donde se originó la consulta.';


--
-- Name: COLUMN assistant_queries.conversation_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.conversation_type IS 'Tipo de conversación donde se realizó la consulta (human o assistant).';


--
-- Name: COLUMN assistant_queries.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.user_id IS 'Usuario que realiza la consulta.';


--
-- Name: COLUMN assistant_queries.frozen_role_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.frozen_role_name IS 'Rol del usuario al momento de consultar (family, caregiver, doctor, elder).';


--
-- Name: COLUMN assistant_queries.query_text; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.query_text IS 'Texto ingresado por el usuario.';


--
-- Name: COLUMN assistant_queries.response_text; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.response_text IS 'Respuesta generada por el asistente de IA.';


--
-- Name: COLUMN assistant_queries.latency_ms; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.latency_ms IS 'Tiempo de respuesta del asistente en milisegundos.';


--
-- Name: COLUMN assistant_queries.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.assistant_queries.created_at IS 'Fecha y hora de la consulta.';


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_user_id uuid,
    action character varying(40) NOT NULL,
    entity_type character varying(40) NOT NULL,
    entity_id uuid,
    patient_id uuid,
    old_value jsonb,
    new_value jsonb,
    ip_address inet,
    user_agent character varying(300),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_audit_log_action CHECK (((action)::text = ANY ((ARRAY['view_record'::character varying, 'create'::character varying, 'update'::character varying, 'delete'::character varying, 'dose_log'::character varying, 'alert_ack'::character varying, 'alert_resolve'::character varying, 'sos_trigger'::character varying, 'threshold_update'::character varying, 'member_add'::character varying, 'member_remove'::character varying, 'login'::character varying])::text[])))
);


--
-- Name: TABLE audit_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.audit_log IS 'Registro inmutable (append-only) de accesos y cambios sobre datos clínicos. Cumple RNF-14 (trazabilidad clínica). Un trigger bloquea UPDATE y DELETE: la evidencia de auditoría no se puede alterar.';


--
-- Name: COLUMN audit_log.actor_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.actor_user_id IS 'Quién ejecutó la acción. ON DELETE RESTRICT: la evidencia de auditoría no se puede perder.';


--
-- Name: COLUMN audit_log.action; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.action IS 'Verbo del dominio: view_record (lectura de expediente), dose_log, alert_ack, etc.';


--
-- Name: COLUMN audit_log.old_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.old_value IS 'Estado anterior del recurso en un cambio. jsonb INTENCIONAL: la auditoría registra entidades heterogéneas.';


--
-- Name: COLUMN audit_log.new_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.new_value IS 'Estado nuevo del recurso en un cambio.';


--
-- Name: billing_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    plan_price_id uuid,
    type character varying(20) NOT NULL,
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    amount numeric(12,2),
    currency character(3),
    period_start timestamp with time zone,
    period_end timestamp with time zone,
    provider_ref character varying(120),
    provider_event_id character varying(120),
    failure_reason character varying(200),
    occurred_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_billing_events_currency CHECK (((currency IS NULL) OR (currency ~ '^[A-Z]{3}$'::text))),
    CONSTRAINT ck_billing_events_fallo CHECK ((((status)::text <> 'failed'::text) OR (failure_reason IS NOT NULL))),
    CONSTRAINT ck_billing_events_moneda CHECK (((amount IS NULL) = (currency IS NULL))),
    CONSTRAINT ck_billing_events_periodo CHECK (((period_end IS NULL) OR (period_start IS NULL) OR (period_end > period_start))),
    CONSTRAINT ck_billing_events_signo CHECK (((amount IS NULL) OR (((type)::text = ANY ((ARRAY['refund'::character varying, 'chargeback'::character varying])::text[])) AND (amount <= (0)::numeric)) OR (((type)::text <> ALL ((ARRAY['refund'::character varying, 'chargeback'::character varying])::text[])) AND (amount >= (0)::numeric)))),
    CONSTRAINT ck_billing_events_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'succeeded'::character varying, 'failed'::character varying])::text[]))),
    CONSTRAINT ck_billing_events_type CHECK (((type)::text = ANY ((ARRAY['trial_started'::character varying, 'charge'::character varying, 'renewal'::character varying, 'refund'::character varying, 'chargeback'::character varying, 'payment_failed'::character varying, 'plan_changed'::character varying, 'cancelled'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: TABLE billing_events; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.billing_events IS 'Eventos de facturacion de cada suscripcion. Append-only. No almacena ningun dato de tarjeta, solo referencias opacas de la pasarela. RF-73, RF-83 a RF-85.';


--
-- Name: COLUMN billing_events.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.id IS 'Identificador del evento.';


--
-- Name: COLUMN billing_events.subscription_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.subscription_id IS 'Suscripcion a la que corresponde el evento.';


--
-- Name: COLUMN billing_events.plan_price_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.plan_price_id IS 'Precio vigente con que se emitio el cobro. Conserva el monto historico.';


--
-- Name: COLUMN billing_events.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.type IS 'Tipo de evento: cobro, renovacion, reembolso, fallo, cambio de plan, baja.';


--
-- Name: COLUMN billing_events.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.status IS 'Resultado del evento: pending, succeeded o failed.';


--
-- Name: COLUMN billing_events.amount; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.amount IS 'Monto del evento. Negativo en reembolsos y contracargos.';


--
-- Name: COLUMN billing_events.currency; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.currency IS 'Moneda del monto, en codigo ISO de tres letras.';


--
-- Name: COLUMN billing_events.period_start; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.period_start IS 'Inicio del periodo que cubre el cobro.';


--
-- Name: COLUMN billing_events.period_end; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.period_end IS 'Fin del periodo que cubre el cobro.';


--
-- Name: COLUMN billing_events.provider_ref; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.provider_ref IS 'Referencia opaca de la transaccion en la pasarela.';


--
-- Name: COLUMN billing_events.provider_event_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.provider_event_id IS 'Identificador del aviso de la pasarela. Unico, para que un reintento no duplique el cobro.';


--
-- Name: COLUMN billing_events.failure_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.failure_reason IS 'Motivo del fallo. Obligatorio cuando el estado es failed.';


--
-- Name: COLUMN billing_events.occurred_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.occurred_at IS 'Momento en que ocurrio el evento segun la pasarela.';


--
-- Name: COLUMN billing_events.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_events.created_at IS 'Momento en que el evento se registro en AgeCare.';


--
-- Name: care_observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.care_observations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    author_id uuid NOT NULL,
    category character varying(20) NOT NULL,
    note character varying(1000) NOT NULL,
    photo_file_id uuid,
    observed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_care_observations_category CHECK (((category)::text = ANY ((ARRAY['mood'::character varying, 'food'::character varying, 'hygiene'::character varying, 'sleep'::character varying, 'mobility'::character varying, 'pain'::character varying, 'medication'::character varying, 'visit'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT ck_care_observations_note CHECK ((btrim((note)::text) <> ''::text))
);


--
-- Name: TABLE care_observations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.care_observations IS 'Observaciones que registra la cuidadora sobre el dia del paciente. Nucleo de la bitacora del expediente. RF-34, RF-35.';


--
-- Name: COLUMN care_observations.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.id IS 'Identificador de la observacion.';


--
-- Name: COLUMN care_observations.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.patient_id IS 'Paciente observado.';


--
-- Name: COLUMN care_observations.author_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.author_id IS 'Usuario que escribio la observacion.';


--
-- Name: COLUMN care_observations.category; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.category IS 'Categoria de la observacion. Lista cerrada para que RF-35 pueda filtrar.';


--
-- Name: COLUMN care_observations.note; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.note IS 'Texto de la observacion. No puede quedar vacio.';


--
-- Name: COLUMN care_observations.photo_file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.photo_file_id IS 'Foto adjunta opcional (RF-34).';


--
-- Name: COLUMN care_observations.observed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.observed_at IS 'Momento en que ocurrio lo observado. Lo informa quien registra.';


--
-- Name: COLUMN care_observations.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.created_at IS 'Momento en que la observacion entro al sistema.';


--
-- Name: COLUMN care_observations.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.updated_at IS 'Fecha de la ultima correccion del texto.';


--
-- Name: COLUMN care_observations.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_observations.deleted_at IS 'Marca de baja. La fila se conserva, deja de mostrarse.';


--
-- Name: care_shifts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.care_shifts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    caregiver_id uuid NOT NULL,
    checked_in_at timestamp with time zone DEFAULT now() NOT NULL,
    checked_out_at timestamp with time zone,
    in_latitude numeric(9,6),
    in_longitude numeric(9,6),
    out_latitude numeric(9,6),
    out_longitude numeric(9,6),
    duration_seconds integer GENERATED ALWAYS AS ((EXTRACT(epoch FROM (checked_out_at - checked_in_at)))::integer) STORED,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_care_shifts_coord_entrada CHECK (((in_latitude IS NULL) = (in_longitude IS NULL))),
    CONSTRAINT ck_care_shifts_coord_salida CHECK (((out_latitude IS NULL) = (out_longitude IS NULL))),
    CONSTRAINT ck_care_shifts_lat CHECK ((((in_latitude IS NULL) OR ((in_latitude >= ('-90'::integer)::numeric) AND (in_latitude <= (90)::numeric))) AND ((out_latitude IS NULL) OR ((out_latitude >= ('-90'::integer)::numeric) AND (out_latitude <= (90)::numeric))))),
    CONSTRAINT ck_care_shifts_lng CHECK ((((in_longitude IS NULL) OR ((in_longitude >= ('-180'::integer)::numeric) AND (in_longitude <= (180)::numeric))) AND ((out_longitude IS NULL) OR ((out_longitude >= ('-180'::integer)::numeric) AND (out_longitude <= (180)::numeric))))),
    CONSTRAINT ck_care_shifts_orden CHECK (((checked_out_at IS NULL) OR (checked_out_at >= checked_in_at))),
    CONSTRAINT ck_care_shifts_salida_coherente CHECK (((checked_out_at IS NOT NULL) OR (out_latitude IS NULL)))
);


--
-- Name: TABLE care_shifts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.care_shifts IS 'Turno de cuidado con marca de entrada y salida. Una fila sin checked_out_at es un turno en curso.';


--
-- Name: COLUMN care_shifts.duration_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_shifts.duration_seconds IS 'Duracion del turno en segundos, calculada por el motor. NULL mientras el turno sigue abierto.';


--
-- Name: care_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.care_tasks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    assigned_to_user_id uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    title character varying(150) NOT NULL,
    description text,
    due_date date NOT NULL,
    due_time time without time zone,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    completed_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    category character varying(20),
    CONSTRAINT chk_care_tasks_completed CHECK (((((status)::text = 'completed'::text) AND (completed_at IS NOT NULL)) OR (((status)::text <> 'completed'::text) AND (completed_at IS NULL)))),
    CONSTRAINT chk_care_tasks_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'in_progress'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[]))),
    CONSTRAINT ck_care_tasks_category CHECK (((category IS NULL) OR ((category)::text = ANY ((ARRAY['hygiene'::character varying, 'medication'::character varying, 'food'::character varying, 'activity'::character varying, 'company'::character varying, 'other'::character varying])::text[]))))
);


--
-- Name: TABLE care_tasks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.care_tasks IS 'Listado de tareas de asistencia y rutinas diarias del círculo de cuidado.';


--
-- Name: COLUMN care_tasks.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.id IS 'Identificador único de la tarea de cuidado.';


--
-- Name: COLUMN care_tasks.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.patient_id IS 'Paciente receptor del cuidado.';


--
-- Name: COLUMN care_tasks.assigned_to_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.assigned_to_user_id IS 'Cuidador o familiar responsable de ejecutar la tarea.';


--
-- Name: COLUMN care_tasks.created_by_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.created_by_user_id IS 'Usuario que asignó la tarea (ej: familiar administrador).';


--
-- Name: COLUMN care_tasks.title; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.title IS 'Título o resumen de la tarea.';


--
-- Name: COLUMN care_tasks.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.description IS 'Detalles o instrucciones específicas para la tarea.';


--
-- Name: COLUMN care_tasks.due_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.due_date IS 'Fecha límite para realizar la tarea.';


--
-- Name: COLUMN care_tasks.due_time; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.due_time IS 'Hora específica sugerida para la tarea (opcional).';


--
-- Name: COLUMN care_tasks.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.status IS 'Estado actual de la tarea: pending, in_progress, completed, cancelled.';


--
-- Name: COLUMN care_tasks.completed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.completed_at IS 'Fecha y hora exacta en que se marcó como completada.';


--
-- Name: COLUMN care_tasks.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.deleted_at IS 'Fecha y hora de eliminación lógica.';


--
-- Name: COLUMN care_tasks.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.created_at IS 'Fecha y hora de creación de la tarea.';


--
-- Name: COLUMN care_tasks.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.updated_at IS 'Fecha y hora de última actualización.';


--
-- Name: COLUMN care_tasks.category; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.care_tasks.category IS 'Tipo de tarea, lista cerrada, opcional. Permite contar tareas por tipo en los informes de la cuidadora.';


--
-- Name: caregiver_certifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caregiver_certifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile_id uuid NOT NULL,
    name character varying(120) NOT NULL,
    issuer character varying(120) NOT NULL,
    issued_at date,
    expires_at date,
    verified_at timestamp with time zone,
    verified_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    file_id uuid,
    file_scope character varying(12),
    CONSTRAINT ck_caregiver_certifications_file_scope CHECK ((((file_id IS NULL) AND (file_scope IS NULL)) OR ((file_id IS NOT NULL) AND ((file_scope)::text = 'caregiver'::text)))),
    CONSTRAINT ck_caregiver_certifications_issuer CHECK ((btrim((issuer)::text) <> ''::text)),
    CONSTRAINT ck_caregiver_certifications_name CHECK ((btrim((name)::text) <> ''::text)),
    CONSTRAINT ck_caregiver_certifications_verificacion CHECK (((verified_at IS NULL) = (verified_by IS NULL))),
    CONSTRAINT ck_caregiver_certifications_verificado CHECK (((verified_at IS NULL) OR (file_id IS NOT NULL))),
    CONSTRAINT ck_caregiver_certifications_vigencia CHECK (((expires_at IS NULL) OR (issued_at IS NULL) OR (expires_at > issued_at)))
);


--
-- Name: TABLE caregiver_certifications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.caregiver_certifications IS 'Certificaciones declaradas por cada cuidadora, con vigencia y verificación. Normalización 1FN. El respaldo no apunta a files porque files exige un paciente y un certificado no pertenece a ninguno. RF-72, RF-76.';


--
-- Name: COLUMN caregiver_certifications.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.id IS 'Identificador de la certificación.';


--
-- Name: COLUMN caregiver_certifications.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.profile_id IS 'Perfil que declara la certificación.';


--
-- Name: COLUMN caregiver_certifications.name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.name IS 'Nombre del curso o título obtenido.';


--
-- Name: COLUMN caregiver_certifications.issuer; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.issuer IS 'Institución que lo emitió.';


--
-- Name: COLUMN caregiver_certifications.issued_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.issued_at IS 'Fecha de emisión.';


--
-- Name: COLUMN caregiver_certifications.expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.expires_at IS 'Fecha de vencimiento. Nula si el certificado no vence.';


--
-- Name: COLUMN caregiver_certifications.verified_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.verified_at IS 'Momento en que alguien revisó el documento y dio por válida la certificación.';


--
-- Name: COLUMN caregiver_certifications.verified_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.verified_by IS 'Quién la verificó.';


--
-- Name: COLUMN caregiver_certifications.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.created_at IS 'Fecha de creación del registro.';


--
-- Name: COLUMN caregiver_certifications.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.updated_at IS 'Fecha de la última modificación del registro.';


--
-- Name: COLUMN caregiver_certifications.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.deleted_at IS 'Baja lógica. La fila se conserva.';


--
-- Name: COLUMN caregiver_certifications.file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.file_id IS 'Documento de respaldo, en la tabla files con ámbito caregiver. Reemplaza las columnas de almacenamiento que esta tabla guardaba en línea.';


--
-- Name: COLUMN caregiver_certifications.file_scope; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_certifications.file_scope IS 'Siempre caregiver. Sostiene la clave foránea compuesta que impide respaldar un certificado con el archivo de un paciente.';


--
-- Name: caregiver_languages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caregiver_languages (
    profile_id uuid NOT NULL,
    language_code character(2) NOT NULL,
    proficiency character varying(14) DEFAULT 'conversational'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_caregiver_languages_code CHECK ((language_code ~ '^[a-z]{2}$'::text)),
    CONSTRAINT ck_caregiver_languages_nivel CHECK (((proficiency)::text = ANY (ARRAY[('basic'::character varying)::text, ('conversational'::character varying)::text, ('fluent'::character varying)::text, ('native'::character varying)::text])))
);


--
-- Name: TABLE caregiver_languages; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.caregiver_languages IS 'Idiomas que habla cada cuidadora, uno por fila. Normalización 1FN. RF-72, RF-75.';


--
-- Name: COLUMN caregiver_languages.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_languages.profile_id IS 'Perfil que declara el idioma.';


--
-- Name: COLUMN caregiver_languages.language_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_languages.language_code IS 'Código ISO 639-1 de dos letras. El nombre visible lo resuelve la aplicación.';


--
-- Name: COLUMN caregiver_languages.proficiency; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_languages.proficiency IS 'Nivel de dominio del idioma. El largo de la columna alcanza para el valor mas largo del CHECK, que es conversational.';


--
-- Name: COLUMN caregiver_languages.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_languages.created_at IS 'Fecha de creación del registro.';


--
-- Name: caregiver_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caregiver_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    headline character varying(120) NOT NULL,
    bio character varying(2000),
    years_experience smallint DEFAULT 0 NOT NULL,
    hourly_rate numeric(12,2),
    currency character(3) DEFAULT 'CLP'::bpchar NOT NULL,
    availability character varying(12) DEFAULT 'part_time'::character varying NOT NULL,
    accepts_overnight boolean DEFAULT false NOT NULL,
    status character varying(12) DEFAULT 'draft'::character varying NOT NULL,
    rating_avg numeric(3,2),
    rating_count integer DEFAULT 0 NOT NULL,
    published_at timestamp with time zone,
    suspended_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_caregiver_profiles_currency CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT ck_caregiver_profiles_disponibilidad CHECK (((availability)::text = ANY ((ARRAY['full_time'::character varying, 'part_time'::character varying, 'hourly'::character varying, 'live_in'::character varying, 'weekends'::character varying])::text[]))),
    CONSTRAINT ck_caregiver_profiles_experiencia CHECK (((years_experience >= 0) AND (years_experience <= 70))),
    CONSTRAINT ck_caregiver_profiles_headline CHECK ((btrim((headline)::text) <> ''::text)),
    CONSTRAINT ck_caregiver_profiles_rating CHECK (((rating_avg IS NULL) OR ((rating_avg >= (1)::numeric) AND (rating_avg <= (5)::numeric)))),
    CONSTRAINT ck_caregiver_profiles_rating_count CHECK ((rating_count >= 0)),
    CONSTRAINT ck_caregiver_profiles_rating_par CHECK (((rating_avg IS NULL) = (rating_count = 0))),
    CONSTRAINT ck_caregiver_profiles_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'suspended'::character varying])::text[]))),
    CONSTRAINT ck_caregiver_profiles_status_fechas CHECK (((((status)::text = 'draft'::text) AND (published_at IS NULL) AND (suspended_at IS NULL)) OR (((status)::text = 'published'::text) AND (published_at IS NOT NULL) AND (suspended_at IS NULL)) OR (((status)::text = 'suspended'::text) AND (published_at IS NOT NULL) AND (suspended_at IS NOT NULL)))),
    CONSTRAINT ck_caregiver_profiles_tarifa CHECK (((hourly_rate IS NULL) OR (hourly_rate >= (0)::numeric)))
);


--
-- Name: TABLE caregiver_profiles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.caregiver_profiles IS 'Perfil profesional de una cuidadora en el marketplace. Separado de users porque la mayoría de los usuarios nunca tiene perfil profesional. Sus listas (especialidades, idiomas, zonas, certificaciones) viven en tablas aparte por 1FN. RF-72, RF-76.';


--
-- Name: COLUMN caregiver_profiles.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.id IS 'Identificador del perfil.';


--
-- Name: COLUMN caregiver_profiles.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.user_id IS 'Usuario dueño del perfil. Único: una persona tiene un solo perfil profesional.';


--
-- Name: COLUMN caregiver_profiles.headline; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.headline IS 'Titular corto que resume la oferta, por ejemplo Cuidadora con 8 años en demencias.';


--
-- Name: COLUMN caregiver_profiles.bio; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.bio IS 'Presentación extendida que lee el familiar en el perfil público.';


--
-- Name: COLUMN caregiver_profiles.years_experience; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.years_experience IS 'Años de experiencia declarados.';


--
-- Name: COLUMN caregiver_profiles.hourly_rate; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.hourly_rate IS 'Tarifa por hora de referencia. Nula si prefiere conversarla.';


--
-- Name: COLUMN caregiver_profiles.currency; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.currency IS 'Moneda de la tarifa, en código ISO de tres letras.';


--
-- Name: COLUMN caregiver_profiles.availability; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.availability IS 'Modalidad de disponibilidad declarada.';


--
-- Name: COLUMN caregiver_profiles.accepts_overnight; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.accepts_overnight IS 'Si acepta turnos de noche.';


--
-- Name: COLUMN caregiver_profiles.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.status IS 'Estado del perfil: draft, published o suspended. Solo los published salen en la búsqueda.';


--
-- Name: COLUMN caregiver_profiles.rating_avg; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.rating_avg IS 'Promedio de calificación. Valor DERIVADO de caregiver_reviews, almacenado para que RF-75 pueda ordenar sin recalcular. Lo mantiene un trigger, no la aplicación.';


--
-- Name: COLUMN caregiver_profiles.rating_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.rating_count IS 'Cantidad de reseñas vigentes. También derivado y mantenido por el mismo trigger.';


--
-- Name: COLUMN caregiver_profiles.published_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.published_at IS 'Momento en que el perfil quedó visible en el marketplace.';


--
-- Name: COLUMN caregiver_profiles.suspended_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.suspended_at IS 'Momento en que el perfil se suspendió. La fila se conserva.';


--
-- Name: COLUMN caregiver_profiles.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.created_at IS 'Fecha de creación del registro.';


--
-- Name: COLUMN caregiver_profiles.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.updated_at IS 'Fecha de la última modificación del registro.';


--
-- Name: COLUMN caregiver_profiles.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_profiles.deleted_at IS 'Baja lógica. El perfil se conserva porque hay reseñas y solicitudes que lo referencian.';


--
-- Name: caregiver_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caregiver_reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile_id uuid NOT NULL,
    reviewed_user_id uuid NOT NULL,
    author_id uuid NOT NULL,
    patient_id uuid NOT NULL,
    rating smallint NOT NULL,
    comment character varying(1000),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_caregiver_reviews_comentario CHECK (((comment IS NULL) OR (btrim((comment)::text) <> ''::text))),
    CONSTRAINT ck_caregiver_reviews_no_autoresena CHECK ((author_id <> reviewed_user_id)),
    CONSTRAINT ck_caregiver_reviews_rating CHECK (((rating >= 1) AND (rating <= 5)))
);


--
-- Name: TABLE caregiver_reviews; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.caregiver_reviews IS 'Reseñas que dejan los familiares a las cuidadoras. Las dos condiciones de RF-78, una sola vez y solo quien la tuvo en su círculo, las impone el motor con un UNIQUE y dos claves foráneas compuestas contra patient_members. RF-76, RF-78.';


--
-- Name: COLUMN caregiver_reviews.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.id IS 'Identificador de la reseña.';


--
-- Name: COLUMN caregiver_reviews.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.profile_id IS 'Perfil reseñado.';


--
-- Name: COLUMN caregiver_reviews.reviewed_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.reviewed_user_id IS 'Usuario dueño de ese perfil. Se guarda para poder verificar contra patient_members que la cuidadora estuvo en el círculo.';


--
-- Name: COLUMN caregiver_reviews.author_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.author_id IS 'Usuario que escribe la reseña.';


--
-- Name: COLUMN caregiver_reviews.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.patient_id IS 'Círculo de cuidado en el que compartieron. Es la pieza que permite verificar RF-78.';


--
-- Name: COLUMN caregiver_reviews.rating; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.rating IS 'Calificación de 1 a 5.';


--
-- Name: COLUMN caregiver_reviews.comment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.comment IS 'Texto de la reseña. Opcional, pero si viene no puede estar en blanco.';


--
-- Name: COLUMN caregiver_reviews.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.created_at IS 'Fecha de creación del registro.';


--
-- Name: COLUMN caregiver_reviews.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.updated_at IS 'Fecha de la última modificación del registro.';


--
-- Name: COLUMN caregiver_reviews.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_reviews.deleted_at IS 'Baja lógica. La reseña se conserva y deja de contar en el promedio.';


--
-- Name: caregiver_specialties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caregiver_specialties (
    profile_id uuid NOT NULL,
    specialty_code character varying(40) NOT NULL,
    years smallint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_caregiver_specialties_years CHECK (((years IS NULL) OR ((years >= 0) AND (years <= 70))))
);


--
-- Name: TABLE caregiver_specialties; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.caregiver_specialties IS 'Especialidades declaradas por cada cuidadora. Normalización 1FN: reemplaza lo que sería una lista dentro del perfil. RF-72, RF-75.';


--
-- Name: COLUMN caregiver_specialties.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_specialties.profile_id IS 'Perfil que declara la especialidad.';


--
-- Name: COLUMN caregiver_specialties.specialty_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_specialties.specialty_code IS 'Especialidad declarada. Apunta al catálogo, así que no se puede inventar una.';


--
-- Name: COLUMN caregiver_specialties.years; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_specialties.years IS 'Años de experiencia en esa especialidad en particular. Opcional.';


--
-- Name: COLUMN caregiver_specialties.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_specialties.created_at IS 'Fecha de creación del registro.';


--
-- Name: caregiver_zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caregiver_zones (
    profile_id uuid NOT NULL,
    commune_code character(5) NOT NULL,
    travel_fee numeric(12,2),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_caregiver_zones_code CHECK ((commune_code ~ '^[0-9]{5}$'::text)),
    CONSTRAINT ck_caregiver_zones_fee CHECK (((travel_fee IS NULL) OR (travel_fee >= (0)::numeric)))
);


--
-- Name: TABLE caregiver_zones; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.caregiver_zones IS 'Comunas donde atiende cada cuidadora, una por fila. Normalización 1FN. Guarda solo el código oficial, no el nombre, para no incurrir en dependencia transitiva. RF-72, RF-75.';


--
-- Name: COLUMN caregiver_zones.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_zones.profile_id IS 'Perfil que atiende la comuna.';


--
-- Name: COLUMN caregiver_zones.commune_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_zones.commune_code IS 'Código de comuna del INE, cinco dígitos. El nombre lo resuelve la aplicación contra la lista oficial.';


--
-- Name: COLUMN caregiver_zones.travel_fee; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_zones.travel_fee IS 'Recargo por traslado a esa comuna, si cobra uno.';


--
-- Name: COLUMN caregiver_zones.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caregiver_zones.created_at IS 'Fecha de creación del registro.';


--
-- Name: chat_ws_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_ws_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    patient_id uuid NOT NULL,
    worker_pid integer NOT NULL,
    connected_at timestamp with time zone DEFAULT now() NOT NULL,
    last_ping_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE chat_ws_sessions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.chat_ws_sessions IS 'Sesiones WebSocket activas del chat. Un worker la registra al conectar y la borra al desconectar. RF-54.';


--
-- Name: condition_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.condition_catalog (
    code character varying(40) NOT NULL,
    label character varying(100) NOT NULL,
    system character varying(20) NOT NULL,
    CONSTRAINT ck_condition_catalog_system CHECK (((system)::text = ANY ((ARRAY['cardiovascular'::character varying, 'respiratorio'::character varying, 'geriatrico'::character varying, 'metabolico'::character varying, 'osteomuscular'::character varying, 'neuropsiquiatrico'::character varying, 'sensorial'::character varying, 'otras'::character varying])::text[])))
);


--
-- Name: TABLE condition_catalog; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.condition_catalog IS 'Catálogo semilla de patologías agrupadas por sistema, tomado de la ficha EMPAM/CESFAM. El médico puede elegir del catálogo (hereda el sistema) o escribir libre (queda en otras).';


--
-- Name: contact_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contact_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile_id uuid NOT NULL,
    requester_id uuid NOT NULL,
    patient_id uuid,
    message character varying(1000) NOT NULL,
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    channel character varying(12),
    responded_at timestamp with time zone,
    decline_reason character varying(200),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_contact_requests_canal_si_acepta CHECK (((((status)::text = 'accepted'::text) AND (channel IS NOT NULL)) OR (((status)::text <> 'accepted'::text) AND (channel IS NULL)))),
    CONSTRAINT ck_contact_requests_channel CHECK (((channel IS NULL) OR ((channel)::text = ANY ((ARRAY['phone'::character varying, 'email'::character varying, 'chat'::character varying])::text[])))),
    CONSTRAINT ck_contact_requests_message CHECK ((btrim((message)::text) <> ''::text)),
    CONSTRAINT ck_contact_requests_rechazo CHECK ((((status)::text = 'declined'::text) OR (decline_reason IS NULL))),
    CONSTRAINT ck_contact_requests_respuesta CHECK (((((status)::text = 'pending'::text) AND (responded_at IS NULL)) OR (((status)::text <> 'pending'::text) AND (responded_at IS NOT NULL)))),
    CONSTRAINT ck_contact_requests_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying, 'expired'::character varying, 'withdrawn'::character varying])::text[])))
);


--
-- Name: TABLE contact_requests; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.contact_requests IS 'Solicitudes de contacto que un familiar envía a una cuidadora del marketplace, con su estado y el canal entregado al aceptar. RF-77.';


--
-- Name: COLUMN contact_requests.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.id IS 'Identificador de la solicitud.';


--
-- Name: COLUMN contact_requests.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.profile_id IS 'Cuidadora a la que se contacta.';


--
-- Name: COLUMN contact_requests.requester_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.requester_id IS 'Usuario que envía la solicitud.';


--
-- Name: COLUMN contact_requests.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.patient_id IS 'Paciente para el que se busca cuidado. Opcional, porque se puede buscar antes de crear el expediente.';


--
-- Name: COLUMN contact_requests.message; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.message IS 'Mensaje inicial del familiar.';


--
-- Name: COLUMN contact_requests.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.status IS 'Estado de la solicitud: pending, accepted, declined, expired o withdrawn.';


--
-- Name: COLUMN contact_requests.channel; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.channel IS 'Canal entregado al aceptar: phone, email o chat. Nulo mientras no haya aceptación.';


--
-- Name: COLUMN contact_requests.responded_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.responded_at IS 'Momento en que la solicitud dejó de estar pendiente.';


--
-- Name: COLUMN contact_requests.decline_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.decline_reason IS 'Motivo del rechazo, cuando la cuidadora decide no aceptar.';


--
-- Name: COLUMN contact_requests.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.created_at IS 'Fecha de creación del registro.';


--
-- Name: COLUMN contact_requests.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.contact_requests.updated_at IS 'Fecha de la última modificación del registro.';


--
-- Name: content_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title character varying(150) NOT NULL,
    category character varying(30) NOT NULL,
    media_type character varying(20) NOT NULL,
    file_id uuid,
    external_url text,
    duration_seconds integer,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    file_scope character varying(12),
    CONSTRAINT chk_content_items_category CHECK (((category)::text = ANY ((ARRAY['music'::character varying, 'radio'::character varying, 'audiobook'::character varying, 'game'::character varying, 'exercise'::character varying])::text[]))),
    CONSTRAINT chk_content_items_duration CHECK (((duration_seconds IS NULL) OR (duration_seconds > 0))),
    CONSTRAINT chk_content_items_media_type CHECK (((media_type)::text = ANY ((ARRAY['audio'::character varying, 'video'::character varying, 'interactive'::character varying])::text[]))),
    CONSTRAINT chk_content_items_source CHECK ((((file_id IS NOT NULL) AND (external_url IS NULL)) OR ((file_id IS NULL) AND (external_url IS NOT NULL)))),
    CONSTRAINT ck_content_items_file_scope CHECK ((((file_id IS NULL) AND (file_scope IS NULL)) OR ((file_id IS NOT NULL) AND ((file_scope)::text = 'catalog'::text))))
);


--
-- Name: COLUMN content_items.file_scope; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_items.file_scope IS 'Siempre catalog. Existe para que la clave foránea compuesta impida que un ítem del catálogo apunte al archivo de un paciente.';


--
-- Name: content_playbacks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_playbacks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    content_item_id uuid NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    playback_seconds integer DEFAULT 0 NOT NULL,
    completed boolean DEFAULT false NOT NULL,
    started_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_at timestamp with time zone,
    CONSTRAINT chk_content_playbacks_seconds CHECK ((playback_seconds >= 0)),
    CONSTRAINT chk_content_playbacks_time CHECK (((finished_at IS NULL) OR (finished_at >= started_at)))
);


--
-- Name: TABLE content_playbacks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.content_playbacks IS 'Historial y métricas de consumo de contenido multimedia por parte del paciente.';


--
-- Name: COLUMN content_playbacks.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.id IS 'Identificador único de la sesión de reproducción.';


--
-- Name: COLUMN content_playbacks.content_item_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.content_item_id IS 'Contenido multimedia reproducido.';


--
-- Name: COLUMN content_playbacks.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.patient_id IS 'Paciente que consumió el contenido.';


--
-- Name: COLUMN content_playbacks.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.user_id IS 'Usuario ejecutor (adulto mayor con rol elder).';


--
-- Name: COLUMN content_playbacks.playback_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.playback_seconds IS 'Tiempo total reproducido en segundos.';


--
-- Name: COLUMN content_playbacks.completed; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.completed IS 'Indica si se completó la lectura/reproducción total.';


--
-- Name: COLUMN content_playbacks.started_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.started_at IS 'Fecha y hora de inicio de la reproducción.';


--
-- Name: COLUMN content_playbacks.finished_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.content_playbacks.finished_at IS 'Fecha y hora de finalización.';


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(20) NOT NULL,
    user_id uuid,
    last_message_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    title character varying(120),
    CONSTRAINT chk_conversations_type CHECK (((type)::text = ANY ((ARRAY['human'::character varying, 'assistant'::character varying])::text[]))),
    CONSTRAINT chk_conversations_user_type CHECK (((((type)::text = 'human'::text) AND (user_id IS NULL)) OR (((type)::text = 'assistant'::text) AND (user_id IS NOT NULL)))),
    CONSTRAINT ck_conversations_title CHECK (((title IS NULL) OR (btrim((title)::text) <> ''::text)))
);


--
-- Name: TABLE conversations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.conversations IS 'Hilos de conversación asociados a un paciente (chat del círculo de cuidado e hilos individuales del asistente IA).';


--
-- Name: COLUMN conversations.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.id IS 'Identificador único de la conversación.';


--
-- Name: COLUMN conversations.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.patient_id IS 'Paciente al que pertenece la conversación.';


--
-- Name: COLUMN conversations.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.type IS 'Tipo de canal de conversación: human (círculo de cuidado) o assistant (asistente IA).';


--
-- Name: COLUMN conversations.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.user_id IS 'Usuario propietario del hilo de asistente IA. Nulo para el chat humano global.';


--
-- Name: COLUMN conversations.last_message_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.last_message_at IS 'Fecha y hora del último mensaje para ordenamiento de la bandeja.';


--
-- Name: COLUMN conversations.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.created_at IS 'Fecha y hora de creación del registro.';


--
-- Name: COLUMN conversations.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.updated_at IS 'Fecha y hora de última actualización del registro.';


--
-- Name: COLUMN conversations.title; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.title IS 'Titulo de la conversacion con el asistente, derivado de la primera pregunta. NULL en el chat humano, que es uno solo por paciente y no se lista.';


--
-- Name: creation_shares; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.creation_shares (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    music_creation_id uuid NOT NULL,
    shared_with_user_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    token_hash character varying(64),
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    play_count integer DEFAULT 0 NOT NULL,
    last_played_at timestamp with time zone,
    shared_by uuid,
    CONSTRAINT ck_creation_shares_destino CHECK ((((shared_with_user_id IS NOT NULL) AND (token_hash IS NULL)) OR ((shared_with_user_id IS NULL) AND (token_hash IS NOT NULL)))),
    CONSTRAINT ck_creation_shares_reproducciones CHECK (((play_count >= 0) AND ((play_count = 0) = (last_played_at IS NULL)))),
    CONSTRAINT ck_creation_shares_vigencia CHECK (((token_hash IS NULL) OR (expires_at IS NOT NULL)))
);


--
-- Name: TABLE creation_shares; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.creation_shares IS 'Compartición de una creación musical, con un miembro del círculo o por enlace de escucha con token y vencimiento. El enlace existe para que alguien sin cuenta pueda escuchar sin entrar al expediente. RF-67.';


--
-- Name: COLUMN creation_shares.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.id IS 'Identificador único del registro de compartido.';


--
-- Name: COLUMN creation_shares.music_creation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.music_creation_id IS 'Creación musical que se comparte.';


--
-- Name: COLUMN creation_shares.shared_with_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.shared_with_user_id IS 'Miembro del círculo con quien se comparte. Nulo cuando se compartió por enlace.';


--
-- Name: COLUMN creation_shares.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.created_at IS 'Fecha y hora de compartición.';


--
-- Name: COLUMN creation_shares.token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.token_hash IS 'Hash del token del enlace de escucha. El token en claro no se guarda nunca. Nulo cuando se compartió con un usuario.';


--
-- Name: COLUMN creation_shares.expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.expires_at IS 'Vencimiento del enlace. Obligatorio cuando hay token: un enlace sin caducidad no es un enlace seguro.';


--
-- Name: COLUMN creation_shares.revoked_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.revoked_at IS 'Momento en que se anuló el enlace antes de su vencimiento.';


--
-- Name: COLUMN creation_shares.play_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.play_count IS 'Cuántas veces se escuchó por este enlace.';


--
-- Name: COLUMN creation_shares.last_played_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.last_played_at IS 'Última reproducción. Va de la mano con play_count.';


--
-- Name: COLUMN creation_shares.shared_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.creation_shares.shared_by IS 'Quién compartió la creación.';


--
-- Name: daily_checkins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_checkins (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    checkin_date date NOT NULL,
    mood character varying(10) NOT NULL,
    pain_level smallint,
    slept_well boolean,
    ate_well boolean,
    note character varying(500),
    voice_file_id uuid,
    source character varying(10) DEFAULT 'elder'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_daily_checkins_mood CHECK (((mood)::text = ANY ((ARRAY['good'::character varying, 'regular'::character varying, 'bad'::character varying])::text[]))),
    CONSTRAINT ck_daily_checkins_pain CHECK (((pain_level IS NULL) OR ((pain_level >= 0) AND (pain_level <= 10)))),
    CONSTRAINT ck_daily_checkins_source CHECK (((source)::text = ANY ((ARRAY['elder'::character varying, 'caregiver'::character varying])::text[])))
);


--
-- Name: TABLE daily_checkins; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.daily_checkins IS 'Check-in diario que responde el adulto mayor desde su dispositivo. Uno por paciente y dia. Sin autor porque el adulto mayor no es usuario del sistema. RF-38.';


--
-- Name: COLUMN daily_checkins.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.id IS 'Identificador del check-in.';


--
-- Name: COLUMN daily_checkins.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.patient_id IS 'Adulto mayor que responde.';


--
-- Name: COLUMN daily_checkins.checkin_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.checkin_date IS 'Dia al que corresponde el check-in.';


--
-- Name: COLUMN daily_checkins.mood; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.mood IS 'Como dice sentirse: good, regular o bad.';


--
-- Name: COLUMN daily_checkins.pain_level; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.pain_level IS 'Dolor declarado en escala de 0 a 10. Nulo si no respondio.';


--
-- Name: COLUMN daily_checkins.slept_well; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.slept_well IS 'Si durmio bien. Nulo si no respondio.';


--
-- Name: COLUMN daily_checkins.ate_well; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.ate_well IS 'Si comio bien. Nulo si no respondio.';


--
-- Name: COLUMN daily_checkins.note; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.note IS 'Comentario libre del adulto mayor.';


--
-- Name: COLUMN daily_checkins.voice_file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.voice_file_id IS 'Nota de voz con la respuesta, para operar sin teclado (RNF-20).';


--
-- Name: COLUMN daily_checkins.source; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.source IS 'Quien lo ingreso: elder (el propio adulto mayor) o caregiver (lo tomo la cuidadora).';


--
-- Name: COLUMN daily_checkins.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN daily_checkins.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.daily_checkins.updated_at IS 'Fecha de la ultima correccion del registro.';


--
-- Name: device_link_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_link_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    code_hash character varying(64) NOT NULL,
    created_by uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    attempts smallint DEFAULT 0 NOT NULL,
    used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_device_link_codes_attempts CHECK (((attempts >= 0) AND (attempts <= 5))),
    CONSTRAINT ck_device_link_codes_estado CHECK (((used_at IS NULL) OR (revoked_at IS NULL))),
    CONSTRAINT ck_device_link_codes_vigencia CHECK ((expires_at > created_at))
);


--
-- Name: TABLE device_link_codes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.device_link_codes IS 'Codigos de un solo uso para vincular el dispositivo del adulto mayor sin credenciales. Vencen y se bloquean por intentos fallidos. RF-68.';


--
-- Name: COLUMN device_link_codes.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.id IS 'Identificador del codigo.';


--
-- Name: COLUMN device_link_codes.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.patient_id IS 'Paciente al que quedara vinculado el dispositivo.';


--
-- Name: COLUMN device_link_codes.code_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.code_hash IS 'Hash del codigo. El codigo en claro no se guarda nunca.';


--
-- Name: COLUMN device_link_codes.created_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.created_by IS 'Usuario que genero el codigo.';


--
-- Name: COLUMN device_link_codes.expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.expires_at IS 'Vencimiento del codigo. Corto por diseno, porque el codigo es corto.';


--
-- Name: COLUMN device_link_codes.attempts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.attempts IS 'Intentos fallidos acumulados. Al llegar a 5 el codigo queda inservible.';


--
-- Name: COLUMN device_link_codes.used_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.used_at IS 'Momento en que el codigo se canjeo por un dispositivo vinculado.';


--
-- Name: COLUMN device_link_codes.revoked_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.revoked_at IS 'Momento en que se anulo el codigo antes de usarse.';


--
-- Name: COLUMN device_link_codes.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_link_codes.created_at IS 'Fecha de creacion del registro.';


--
-- Name: doctor_enrollments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.doctor_enrollments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(254) NOT NULL,
    license_number character varying(30) NOT NULL,
    specialty character varying(60),
    token_hash character(64) NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    accepted_by uuid,
    revoked_at timestamp with time zone,
    CONSTRAINT ck_doctor_enrollments_license CHECK ((char_length(btrim((license_number)::text)) >= 3))
);


--
-- Name: TABLE doctor_enrollments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.doctor_enrollments IS 'Codigos con los que un medico crea su cuenta. Los emite el personal tras verificar el registro profesional. Se guarda solo el hash del codigo.';


--
-- Name: doctor_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.doctor_profiles (
    user_id uuid NOT NULL,
    license_number character varying(30) NOT NULL,
    specialty character varying(60),
    verified_at timestamp with time zone DEFAULT now() NOT NULL,
    verified_by uuid,
    revoked_at timestamp with time zone,
    revoked_reason character varying(200),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_doctor_profiles_license CHECK ((char_length(btrim((license_number)::text)) >= 3))
);


--
-- Name: TABLE doctor_profiles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.doctor_profiles IS 'Medicos habilitados por el personal de la empresa. Sin fila vigente (revoked_at NULL) una cuenta no puede operar con el rol doctor sobre ningun paciente, aunque tenga la membresia.';


--
-- Name: COLUMN doctor_profiles.license_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.doctor_profiles.license_number IS 'Numero de registro profesional (Registro Nacional de Prestadores Individuales de la Superintendencia de Salud). Lo verifica una persona del personal antes de crear la habilitacion.';


--
-- Name: COLUMN doctor_profiles.verified_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.doctor_profiles.verified_by IS 'Persona del personal que verifico el registro.';


--
-- Name: drug_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drug_catalog (
    code character varying(40) NOT NULL,
    active_ingredient character varying(100) NOT NULL,
    label character varying(120) NOT NULL,
    form character varying(20) NOT NULL,
    route character varying(20) NOT NULL,
    unit character varying(20) NOT NULL,
    dose_min numeric(8,2) NOT NULL,
    dose_max numeric(8,2) NOT NULL,
    max_daily numeric(8,2),
    CONSTRAINT ck_drug_catalog_range CHECK (((dose_min > (0)::numeric) AND (dose_max >= dose_min)))
);


--
-- Name: TABLE drug_catalog; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.drug_catalog IS 'Catálogo semilla de fármacos. La unidad es ÚNICA por fármaco (no se teclea, se hereda). dose_min/dose_max acotan la dosis segura por toma; la FK a form_route_unit_rules garantiza coherencia forma↔vía↔unidad. Fuente: registro sanitario ISP (estructura) + caso real.';


--
-- Name: elder_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.elder_devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    link_code_id uuid NOT NULL,
    device_label character varying(60) NOT NULL,
    platform character varying(10) NOT NULL,
    device_fingerprint character varying(128) NOT NULL,
    session_token_hash character varying(64) NOT NULL,
    push_token character varying(255),
    app_version character varying(20),
    last_seen_at timestamp with time zone,
    unlinked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid,
    CONSTRAINT ck_elder_devices_label CHECK ((btrim((device_label)::text) <> ''::text)),
    CONSTRAINT ck_elder_devices_platform CHECK (((platform)::text = ANY ((ARRAY['android'::character varying, 'ios'::character varying, 'web'::character varying])::text[])))
);


--
-- Name: TABLE elder_devices; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.elder_devices IS 'Dispositivos vinculados al adulto mayor. La credencial vive en el equipo, no en una cuenta de persona, que es por lo que el adulto mayor no figura en users. RF-68.';


--
-- Name: COLUMN elder_devices.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.id IS 'Identificador del dispositivo.';


--
-- Name: COLUMN elder_devices.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.patient_id IS 'Paciente al que pertenece el dispositivo.';


--
-- Name: COLUMN elder_devices.link_code_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.link_code_id IS 'Codigo de vinculacion con que se dio de alta este dispositivo.';


--
-- Name: COLUMN elder_devices.device_label; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.device_label IS 'Nombre con que la familia reconoce el equipo, por ejemplo tablet del living.';


--
-- Name: COLUMN elder_devices.platform; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.platform IS 'Plataforma del dispositivo: android, ios o web.';


--
-- Name: COLUMN elder_devices.device_fingerprint; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.device_fingerprint IS 'Huella del equipo. Impide reutilizar la sesion en otro dispositivo.';


--
-- Name: COLUMN elder_devices.session_token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.session_token_hash IS 'Hash del token de sesion del dispositivo. Reemplaza al par correo y contrasena.';


--
-- Name: COLUMN elder_devices.push_token; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.push_token IS 'Token de notificaciones del dispositivo, si las recibe.';


--
-- Name: COLUMN elder_devices.app_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.app_version IS 'Version de la aplicacion instalada. Sirve para soporte.';


--
-- Name: COLUMN elder_devices.last_seen_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.last_seen_at IS 'Ultima vez que el dispositivo se comunico con el servidor.';


--
-- Name: COLUMN elder_devices.unlinked_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.unlinked_at IS 'Momento en que se desvinculo. La fila se conserva y el token deja de servir.';


--
-- Name: COLUMN elder_devices.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN elder_devices.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.updated_at IS 'Fecha de la ultima modificacion del registro.';


--
-- Name: COLUMN elder_devices.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_devices.user_id IS 'Cuenta del adulto mayor que este dispositivo representa. La cuenta no permite inicio de sesión (password_hash centinela y correo en dominio reservado); quien autentica es el dispositivo con session_token_hash. Existe para que el adulto mayor pueda figurar como autor en chat, asistente y reacciones.';


--
-- Name: elder_feed_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.elder_feed_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type character varying(12) NOT NULL,
    title character varying(150) NOT NULL,
    body text NOT NULL,
    image_file_id uuid,
    image_scope character varying(12),
    source character varying(120),
    status character varying(12) DEFAULT 'draft'::character varying NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_elder_feed_items_body CHECK ((btrim(body) <> ''::text)),
    CONSTRAINT ck_elder_feed_items_image_scope CHECK ((((image_file_id IS NULL) AND (image_scope IS NULL)) OR ((image_file_id IS NOT NULL) AND ((image_scope)::text = 'catalog'::text)))),
    CONSTRAINT ck_elder_feed_items_source CHECK (((source IS NULL) OR ((type)::text = 'news'::text))),
    CONSTRAINT ck_elder_feed_items_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'archived'::character varying])::text[]))),
    CONSTRAINT ck_elder_feed_items_status_fecha CHECK (((((status)::text = 'draft'::text) AND (published_at IS NULL)) OR (((status)::text <> 'draft'::text) AND (published_at IS NOT NULL)))),
    CONSTRAINT ck_elder_feed_items_title CHECK ((btrim((title)::text) <> ''::text)),
    CONSTRAINT ck_elder_feed_items_type CHECK (((type)::text = ANY ((ARRAY['news'::character varying, 'joke'::character varying, 'memory'::character varying, 'exercise'::character varying, 'tip'::character varying])::text[])))
);


--
-- Name: TABLE elder_feed_items; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.elder_feed_items IS 'Tarjetas de texto del feed Para ti del adulto mayor. Es texto para leer en voz alta, distinto de content_items, que es el catalogo de medios para reproducir.';


--
-- Name: COLUMN elder_feed_items.body; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.elder_feed_items.body IS 'Cuerpo de la tarjeta. La pantalla lo lee en voz alta junto con el titulo, asi que se escribe en frases cortas y sin abreviaturas.';


--
-- Name: emergency_contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.emergency_contacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    first_name character varying(60),
    last_name character varying(60),
    full_name character varying(121) GENERATED ALWAYS AS ((((first_name)::text || ' '::text) || (last_name)::text)) STORED,
    relationship character varying(40),
    phone character varying(16),
    escalation_order smallint DEFAULT 1 NOT NULL,
    notes character varying(200),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    member_user_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT ck_emergency_contacts_first_name CHECK (((first_name IS NULL) OR (char_length((first_name)::text) >= 1))),
    CONSTRAINT ck_emergency_contacts_last_name CHECK (((last_name IS NULL) OR (char_length((last_name)::text) >= 1))),
    CONSTRAINT ck_emergency_contacts_order CHECK (((escalation_order >= 1) AND (escalation_order <= 10))),
    CONSTRAINT ck_emergency_contacts_origen CHECK (((member_user_id IS NOT NULL) OR ((first_name IS NOT NULL) AND (phone IS NOT NULL)))),
    CONSTRAINT ck_emergency_contacts_phone CHECK (((phone IS NULL) OR ((phone)::text ~ '^\+[0-9]{8,15}$'::text)))
);


--
-- Name: TABLE emergency_contacts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.emergency_contacts IS 'Contactos de emergencia del paciente, en orden de escalamiento. No está en el Anexo A: se agrega porque el endpoint 9.6 debe devolver estos teléfonos y el RF-52 exige escalar a los siguientes cuando nadie atiende.';


--
-- Name: COLUMN emergency_contacts.escalation_order; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.emergency_contacts.escalation_order IS 'Prioridad de aviso: 1 primero. Sin este orden, "los siguientes contactos" del RF-52 no se puede implementar.';


--
-- Name: COLUMN emergency_contacts.member_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.emergency_contacts.member_user_id IS 'Miembro del grupo (users.id) que es este contacto. Nombre y teléfono salen de su perfil. NULL solo para contacto libre sin cuenta (no usado aún).';


--
-- Name: COLUMN emergency_contacts.is_active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.emergency_contacts.is_active IS 'Estado de la rotación: true = contacto vigente ahora. Se desactiva (no se borra) cuando la persona deja de estar disponible; se puede reactivar.';


--
-- Name: features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.features (
    code character varying(40) NOT NULL,
    label character varying(80) NOT NULL,
    description character varying(300) NOT NULL,
    module character varying(20) NOT NULL,
    is_core boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_features_code CHECK (((code)::text ~ '^[a-z][a-z0-9_]{2,39}$'::text)),
    CONSTRAINT ck_features_label CHECK ((btrim((label)::text) <> ''::text)),
    CONSTRAINT ck_features_module CHECK (((module)::text = ANY ((ARRAY['health'::character varying, 'medication'::character varying, 'alerts'::character varying, 'logbook'::character varying, 'documents'::character varying, 'chat'::character varying, 'assistant'::character varying, 'elder'::character varying, 'marketplace'::character varying, 'reports'::character varying])::text[])))
);


--
-- Name: TABLE features; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.features IS 'Catalogo de funcionalidades que un plan puede incluir o no. Fuente unica de verdad para RF-73 y para el constructor de planes. RF-83 a RF-85.';


--
-- Name: COLUMN features.code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.features.code IS 'Codigo estable de la funcionalidad. Es lo que consulta la aplicacion.';


--
-- Name: COLUMN features.label; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.features.label IS 'Nombre visible de la funcionalidad.';


--
-- Name: COLUMN features.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.features.description IS 'Que hace la funcionalidad, en lenguaje de usuario.';


--
-- Name: COLUMN features.module; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.features.module IS 'Modulo del sistema al que pertenece.';


--
-- Name: COLUMN features.is_core; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.features.is_core IS 'Verdadero si la funcionalidad es del nucleo y ningun plan puede quitarla.';


--
-- Name: COLUMN features.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.features.created_at IS 'Fecha de creacion del registro.';


--
-- Name: file_ocr; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file_ocr (
    file_id uuid NOT NULL,
    texto text NOT NULL,
    motor character varying(40) NOT NULL,
    idioma character varying(10) DEFAULT 'spa'::character varying NOT NULL,
    confianza numeric(5,2),
    caracteres integer NOT NULL,
    extraido_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_file_ocr_caracteres CHECK ((caracteres >= 0)),
    CONSTRAINT ck_file_ocr_confianza CHECK (((confianza IS NULL) OR ((confianza >= (0)::numeric) AND (confianza <= (100)::numeric))))
);


--
-- Name: TABLE file_ocr; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.file_ocr IS 'Texto extraido de un archivo por OCR. Una fila por archivo; reextraer reemplaza. Alimenta la busqueda y el contexto del asistente.';


--
-- Name: COLUMN file_ocr.confianza; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.file_ocr.confianza IS 'Confianza media del motor (0 a 100). Nula si el motor no la reporta.';


--
-- Name: files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.files (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid,
    uploaded_by uuid NOT NULL,
    storage_key character varying(300) NOT NULL,
    original_name character varying(255) NOT NULL,
    mime_type character varying(100) NOT NULL,
    size_bytes bigint NOT NULL,
    checksum_sha256 character(64),
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    upload_expires_at timestamp with time zone NOT NULL,
    stored_at timestamp with time zone,
    purged_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    scope character varying(12) DEFAULT 'patient'::character varying NOT NULL,
    CONSTRAINT ck_files_mime_type CHECK (((mime_type)::text = ANY ((ARRAY['image/jpeg'::character varying, 'image/png'::character varying, 'image/webp'::character varying, 'image/heic'::character varying, 'application/pdf'::character varying, 'audio/mpeg'::character varying, 'audio/mp4'::character varying, 'audio/aac'::character varying, 'audio/wav'::character varying, 'audio/ogg'::character varying])::text[]))),
    CONSTRAINT ck_files_scope CHECK (((scope)::text = ANY ((ARRAY['patient'::character varying, 'catalog'::character varying, 'caregiver'::character varying, 'user'::character varying])::text[]))),
    CONSTRAINT ck_files_scope_patient CHECK ((((scope)::text = 'patient'::text) = (patient_id IS NOT NULL))),
    CONSTRAINT ck_files_size_bytes CHECK (((size_bytes >= 1) AND (size_bytes <= 26214400))),
    CONSTRAINT ck_files_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'stored'::character varying, 'expired'::character varying, 'purged'::character varying])::text[]))),
    CONSTRAINT ck_files_status_dates CHECK (((((status)::text = 'pending'::text) AND (stored_at IS NULL) AND (purged_at IS NULL)) OR (((status)::text = 'expired'::text) AND (stored_at IS NULL) AND (purged_at IS NULL)) OR (((status)::text = 'stored'::text) AND (stored_at IS NOT NULL) AND (purged_at IS NULL)) OR (((status)::text = 'purged'::text) AND (stored_at IS NOT NULL) AND (purged_at IS NOT NULL))))
);


--
-- Name: TABLE files; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.files IS 'Archivos binarios de todo el sistema. La BD guarda metadatos y la ruta opaca del almacenamiento, nunca el contenido. El ámbito distingue los del expediente de los compartidos. RF-39, RF-42.';


--
-- Name: COLUMN files.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.id IS 'Identificador del archivo.';


--
-- Name: COLUMN files.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.patient_id IS 'Paciente dueño del archivo. Nulo cuando el archivo no pertenece a un expediente, por ejemplo el catálogo de contenido o el certificado de una cuidadora.';


--
-- Name: COLUMN files.uploaded_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.uploaded_by IS 'Usuario que subio el archivo.';


--
-- Name: COLUMN files.storage_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.storage_key IS 'Ruta opaca en el almacenamiento externo. No es adivinable desde la aplicacion.';


--
-- Name: COLUMN files.original_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.original_name IS 'Nombre con que el usuario subio el archivo. Solo para mostrarlo.';


--
-- Name: COLUMN files.mime_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.mime_type IS 'Tipo de contenido, validado contra una lista cerrada (RF-39). Incluye los formatos de audio que genera la aplicacion al grabar notas de voz: aac en Android y wav en grabaciones sin comprimir.';


--
-- Name: COLUMN files.size_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.size_bytes IS 'Tamano en bytes. Techo duro de 25 MB (RF-39).';


--
-- Name: COLUMN files.checksum_sha256; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.checksum_sha256 IS 'Huella SHA-256 del contenido. Permite detectar duplicados y corrupcion.';


--
-- Name: COLUMN files.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.status IS 'Estado del archivo. pending: se entrego el enlace de subida y se espera el binario. stored: el binario esta guardado. expired: el enlace vencio sin que llegara el binario, la fila se conserva como constancia del intento. purged: el binario se elimino del almacenamiento.';


--
-- Name: COLUMN files.upload_expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.upload_expires_at IS 'Vencimiento del enlace de subida. RNF-13 exige 15 minutos o menos.';


--
-- Name: COLUMN files.stored_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.stored_at IS 'Momento en que el almacenamiento confirmo la subida.';


--
-- Name: COLUMN files.purged_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.purged_at IS 'Momento en que se elimino el binario. La fila se conserva como registro (RF-43).';


--
-- Name: COLUMN files.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN files.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.updated_at IS 'Fecha de la ultima modificacion del registro.';


--
-- Name: COLUMN files.scope; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.files.scope IS 'De quien es el archivo. patient: del expediente de un paciente, lo ve su circulo. catalog: contenido comun de la aplicacion. caregiver: certificados que la cuidadora publica en el marketplace. user: archivos de la persona misma, como su foto de perfil, visibles para quienes comparten un circulo con ella.';


--
-- Name: form_route_unit_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.form_route_unit_rules (
    form character varying(20) NOT NULL,
    route character varying(20) NOT NULL,
    unit character varying(20) NOT NULL
);


--
-- Name: TABLE form_route_unit_rules; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.form_route_unit_rules IS 'Coherencia forma↔vía↔unidad. El backend rechaza un fármaco cuya combinación no exista aquí. Evita "parche vía oral" o "aerosol en ml".';


--
-- Name: gallery_photos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gallery_photos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    published_by_user_id uuid NOT NULL,
    file_id uuid NOT NULL,
    caption text,
    display_order integer DEFAULT 0 NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: TABLE gallery_photos; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.gallery_photos IS 'Fotografías familiares publicadas para reproducir en el carrusel del adulto mayor.';


--
-- Name: COLUMN gallery_photos.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.id IS 'Identificador único de la foto de galería.';


--
-- Name: COLUMN gallery_photos.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.patient_id IS 'Paciente destinatario de la foto.';


--
-- Name: COLUMN gallery_photos.published_by_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.published_by_user_id IS 'Usuario que subió la foto.';


--
-- Name: COLUMN gallery_photos.file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.file_id IS 'Referencia al archivo en la tabla files.';


--
-- Name: COLUMN gallery_photos.caption; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.caption IS 'Descripción o pie de foto opcional.';


--
-- Name: COLUMN gallery_photos.display_order; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.display_order IS 'Orden relativo de visualización en la pantalla completa.';


--
-- Name: COLUMN gallery_photos.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.deleted_at IS 'Fecha y hora de eliminación lógica (soft delete).';


--
-- Name: COLUMN gallery_photos.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.created_at IS 'Fecha y hora de publicación.';


--
-- Name: COLUMN gallery_photos.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gallery_photos.updated_at IS 'Fecha y hora de actualización.';


--
-- Name: idempotency_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.idempotency_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    idem_key character varying(80) NOT NULL,
    method character varying(10) NOT NULL,
    path text NOT NULL,
    status_code smallint NOT NULL,
    response_body jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_idempotency_keys_status CHECK (((status_code >= 200) AND (status_code <= 299)))
);


--
-- Name: TABLE idempotency_keys; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.idempotency_keys IS 'Respuesta ya entregada para una clave de reenvio, para que un reintento de la app no duplique la accion (RF-81).';


--
-- Name: COLUMN idempotency_keys.idem_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.idempotency_keys.idem_key IS 'Clave que manda la app en la cabecera Idempotency-Key.';


--
-- Name: COLUMN idempotency_keys.response_body; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.idempotency_keys.response_body IS 'Cuerpo exacto que se le respondio la primera vez, para devolverlo igual.';


--
-- Name: incidents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incidents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    reported_by uuid NOT NULL,
    type character varying(20) NOT NULL,
    severity character varying(10) NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    description character varying(1000) NOT NULL,
    action_taken character varying(1000),
    alert_id uuid,
    photo_file_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_incidents_critical_has_alert CHECK ((((severity)::text <> 'critical'::text) OR (alert_id IS NOT NULL))),
    CONSTRAINT ck_incidents_description CHECK ((btrim((description)::text) <> ''::text)),
    CONSTRAINT ck_incidents_severity CHECK (((severity)::text = ANY ((ARRAY['low'::character varying, 'moderate'::character varying, 'high'::character varying, 'critical'::character varying])::text[]))),
    CONSTRAINT ck_incidents_type CHECK (((type)::text = ANY ((ARRAY['fall'::character varying, 'wandering'::character varying, 'aggression'::character varying, 'refusal'::character varying, 'injury'::character varying, 'choking'::character varying, 'disorientation'::character varying, 'adverse_reaction'::character varying, 'medical_emergency'::character varying, 'other'::character varying])::text[])))
);


--
-- Name: TABLE incidents; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.incidents IS 'Incidentes ocurridos durante el cuidado. Los criticos obligan a tener una alerta asociada. RF-36.';


--
-- Name: COLUMN incidents.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.id IS 'Identificador del incidente.';


--
-- Name: COLUMN incidents.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.patient_id IS 'Paciente afectado.';


--
-- Name: COLUMN incidents.reported_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.reported_by IS 'Usuario que reporto el incidente.';


--
-- Name: COLUMN incidents.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.type IS 'Tipo de incidente, lista cerrada. adverse_reaction es la reaccion adversa a un medicamento y medical_emergency la emergencia que requirio atencion externa.';


--
-- Name: COLUMN incidents.severity; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.severity IS 'Gravedad: low, moderate, high o critical. Critical obliga a generar alerta.';


--
-- Name: COLUMN incidents.occurred_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.occurred_at IS 'Hora en que ocurrio el incidente (RF-36).';


--
-- Name: COLUMN incidents.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.description IS 'Relato de lo ocurrido. No puede quedar vacio.';


--
-- Name: COLUMN incidents.action_taken; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.action_taken IS 'Que se hizo frente al incidente.';


--
-- Name: COLUMN incidents.alert_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.alert_id IS 'Alerta generada por el incidente. Obligatoria cuando la gravedad es critical.';


--
-- Name: COLUMN incidents.photo_file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.photo_file_id IS 'Fotografia de respaldo opcional.';


--
-- Name: COLUMN incidents.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN incidents.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidents.updated_at IS 'Fecha de la ultima modificacion del registro.';


--
-- Name: invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    email character varying(320),
    role character varying(10) NOT NULL,
    token_hash character varying(64) NOT NULL,
    invited_by uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    accepted_by uuid,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    profession character varying(30),
    relationship character varying(20),
    CONSTRAINT ck_invitations_accepted_pair CHECK (((accepted_at IS NULL) = (accepted_by IS NULL))),
    CONSTRAINT ck_invitations_expires CHECK ((expires_at > created_at)),
    CONSTRAINT ck_invitations_not_both CHECK ((NOT ((accepted_at IS NOT NULL) AND (revoked_at IS NOT NULL)))),
    CONSTRAINT ck_invitations_profession CHECK (((profession IS NULL) OR ((profession)::text = ANY ((ARRAY['medico_general'::character varying, 'medico_especialista'::character varying, 'kinesiologo'::character varying, 'enfermera'::character varying, 'podologa'::character varying, 'nutricionista'::character varying, 'fonoaudiologo'::character varying, 'terapeuta_ocupacional'::character varying, 'psicologo'::character varying, 'trabajador_social'::character varying, 'cuidadora'::character varying, 'familiar'::character varying])::text[])))),
    CONSTRAINT ck_invitations_relationship CHECK (((relationship IS NULL) OR ((relationship)::text = ANY ((ARRAY['hijo'::character varying, 'hija'::character varying, 'conyuge'::character varying, 'hermano'::character varying, 'hermana'::character varying, 'nieto'::character varying, 'nieta'::character varying, 'sobrino'::character varying, 'sobrina'::character varying, 'yerno'::character varying, 'nuera'::character varying, 'cuidador'::character varying, 'otro'::character varying])::text[])))),
    CONSTRAINT ck_invitations_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[])))
);


--
-- Name: TABLE invitations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.invitations IS 'Invitaciones al círculo de cuidado. Se invita a un CORREO, no a un usuario: el invitado puede no tener cuenta todavía (endpoints 4.6 y 3.1).';


--
-- Name: COLUMN invitations.email; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.email IS 'Correo del invitado, opcional. NULL cuando el familiar comparte el código por otro medio. Sin clave foránea a users porque puede no existir aún.';


--
-- Name: COLUMN invitations.token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.token_hash IS 'SHA-256 del código de 6 dígitos de la invitación. Nunca en claro: ese código da acceso a un expediente clínico. Único solo entre las pendientes (ver ux_invitations_token).';


--
-- Name: COLUMN invitations.invited_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.invited_by IS 'Quién envió la invitación. Normalmente el familiar administrador.';


--
-- Name: COLUMN invitations.expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.expires_at IS 'Vencimiento. 7 días desde el envío, según el ticket AGE-202.';


--
-- Name: COLUMN invitations.accepted_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.accepted_by IS 'Usuario que aceptó. ON DELETE RESTRICT: la invitación es parte de la historia del paciente y no se pierde.';


--
-- Name: COLUMN invitations.revoked_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.revoked_at IS 'Invitación anulada por el administrador antes de ser aceptada (ticket AGE-207).';


--
-- Name: COLUMN invitations.profession; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.profession IS 'Profesión que tendrá el miembro al aceptar la invitación. Se copia a patient_members.profession.';


--
-- Name: COLUMN invitations.relationship; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.invitations.relationship IS 'Parentesco propuesto para el invitado. Se copia a patient_members.relationship al aceptar.';


--
-- Name: job_offers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_offers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    posted_by uuid NOT NULL,
    title character varying(120) NOT NULL,
    description character varying(2000) NOT NULL,
    commune_code character(5) NOT NULL,
    pay_min numeric(12,2),
    pay_max numeric(12,2),
    pay_period character varying(10) DEFAULT 'hour'::character varying NOT NULL,
    currency character(3) DEFAULT 'CLP'::bpchar NOT NULL,
    schedule character varying(120),
    starts_on date,
    status character varying(12) DEFAULT 'draft'::character varying NOT NULL,
    published_at timestamp with time zone,
    closed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_job_offers_commune CHECK ((commune_code ~ '^[0-9]{5}$'::text)),
    CONSTRAINT ck_job_offers_currency CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT ck_job_offers_desc CHECK ((btrim((description)::text) <> ''::text)),
    CONSTRAINT ck_job_offers_pay_period CHECK (((pay_period)::text = ANY ((ARRAY['hour'::character varying, 'day'::character varying, 'month'::character varying, 'shift'::character varying])::text[]))),
    CONSTRAINT ck_job_offers_pay_positivo CHECK ((((pay_min IS NULL) OR (pay_min >= (0)::numeric)) AND ((pay_max IS NULL) OR (pay_max >= (0)::numeric)))),
    CONSTRAINT ck_job_offers_pay_rango CHECK (((pay_min IS NULL) OR (pay_max IS NULL) OR (pay_max >= pay_min))),
    CONSTRAINT ck_job_offers_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'closed'::character varying])::text[]))),
    CONSTRAINT ck_job_offers_status_fecha CHECK (((((status)::text = 'draft'::text) AND (published_at IS NULL) AND (closed_at IS NULL)) OR (((status)::text = 'published'::text) AND (published_at IS NOT NULL) AND (closed_at IS NULL)) OR (((status)::text = 'closed'::text) AND (published_at IS NOT NULL) AND (closed_at IS NOT NULL)))),
    CONSTRAINT ck_job_offers_title CHECK ((btrim((title)::text) <> ''::text))
);


--
-- Name: TABLE job_offers; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.job_offers IS 'Ofertas de trabajo para cuidadoras. El pago se guarda en numeros y no en texto para poder ordenar y filtrar por monto; el texto que muestra la pantalla se arma al responder.';


--
-- Name: COLUMN job_offers.commune_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.job_offers.commune_code IS 'Comuna del trabajo, con el mismo codigo que caregiver_zones, para poder cruzar una oferta con quienes atienden ahi.';


--
-- Name: limit_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.limit_keys (
    key character varying(40) NOT NULL,
    label character varying(80) NOT NULL,
    description character varying(300) NOT NULL,
    unit character varying(20) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_limit_keys_key CHECK (((key)::text ~ '^[a-z][a-z0-9_]{2,39}$'::text)),
    CONSTRAINT ck_limit_keys_label CHECK ((btrim((label)::text) <> ''::text)),
    CONSTRAINT ck_limit_keys_unit CHECK (((unit)::text = ANY ((ARRAY['count'::character varying, 'days'::character varying, 'months'::character varying, 'megabytes'::character varying, 'per_month'::character varying, 'per_day'::character varying])::text[])))
);


--
-- Name: TABLE limit_keys; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.limit_keys IS 'Catálogo de límites que un plan puede imponer. Existe para corregir una dependencia parcial de 2FN: la unidad de medida depende del límite, no del plan que lo usa.';


--
-- Name: COLUMN limit_keys.key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.limit_keys.key IS 'Nombre del límite, por ejemplo max_patients. Es lo que consulta la aplicación.';


--
-- Name: COLUMN limit_keys.label; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.limit_keys.label IS 'Nombre visible del límite.';


--
-- Name: COLUMN limit_keys.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.limit_keys.description IS 'Qué limita exactamente, en lenguaje de usuario.';


--
-- Name: COLUMN limit_keys.unit; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.limit_keys.unit IS 'Unidad en que se expresa. Depende del límite y de nada más, que es la razón de esta tabla.';


--
-- Name: COLUMN limit_keys.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.limit_keys.created_at IS 'Fecha de creación del registro.';


--
-- Name: market_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.market_products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(120) NOT NULL,
    description character varying(1000) NOT NULL,
    category character varying(20) NOT NULL,
    price numeric(12,2),
    currency character(3) DEFAULT 'CLP'::bpchar NOT NULL,
    supplier character varying(120),
    supplier_url character varying(300),
    image_file_id uuid,
    image_scope character varying(12),
    status character varying(12) DEFAULT 'draft'::character varying NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_market_products_category CHECK (((category)::text = ANY ((ARRAY['mobility'::character varying, 'bathroom'::character varying, 'bedroom'::character varying, 'hygiene'::character varying, 'monitoring'::character varying, 'nutrition'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT ck_market_products_currency CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT ck_market_products_desc CHECK ((btrim((description)::text) <> ''::text)),
    CONSTRAINT ck_market_products_image_scope CHECK ((((image_file_id IS NULL) AND (image_scope IS NULL)) OR ((image_file_id IS NOT NULL) AND ((image_scope)::text = 'catalog'::text)))),
    CONSTRAINT ck_market_products_name CHECK ((btrim((name)::text) <> ''::text)),
    CONSTRAINT ck_market_products_price CHECK (((price IS NULL) OR (price >= (0)::numeric))),
    CONSTRAINT ck_market_products_proveedor CHECK (((supplier_url IS NULL) OR (supplier IS NOT NULL))),
    CONSTRAINT ck_market_products_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'discontinued'::character varying])::text[]))),
    CONSTRAINT ck_market_products_status_fecha CHECK (((((status)::text = 'draft'::text) AND (published_at IS NULL)) OR (((status)::text <> 'draft'::text) AND (published_at IS NOT NULL))))
);


--
-- Name: TABLE market_products; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.market_products IS 'Catalogo de ayudas tecnicas del marketplace. Es informativo: precio referencial y donde conseguirlo, sin stock ni pedidos, porque AgeCare no vende.';


--
-- Name: COLUMN market_products.price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.market_products.price IS 'Precio de referencia, puede ser NULL cuando depende del proveedor.';


--
-- Name: medical_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.medical_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    file_id uuid NOT NULL,
    category character varying(20) NOT NULL,
    title character varying(160) NOT NULL,
    description character varying(500),
    document_date date,
    issued_by character varying(120),
    added_by uuid NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_medical_documents_category CHECK (((category)::text = ANY ((ARRAY['prescription'::character varying, 'lab_result'::character varying, 'imaging'::character varying, 'report'::character varying, 'discharge'::character varying, 'consent'::character varying, 'insurance'::character varying, 'identification'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT ck_medical_documents_delete CHECK (((deleted_at IS NULL) = (deleted_by IS NULL))),
    CONSTRAINT ck_medical_documents_title CHECK ((btrim((title)::text) <> ''::text))
);


--
-- Name: TABLE medical_documents; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.medical_documents IS 'Documentos medicos del expediente. Da significado clinico a un archivo de la tabla files. La baja conserva la fila y la depuracion del binario es posterior. RF-40, RF-41, RF-43.';


--
-- Name: COLUMN medical_documents.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.id IS 'Identificador del documento.';


--
-- Name: COLUMN medical_documents.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.patient_id IS 'Paciente cuyo expediente contiene el documento.';


--
-- Name: COLUMN medical_documents.file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.file_id IS 'Archivo que respalda el documento.';


--
-- Name: COLUMN medical_documents.category; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.category IS 'Tipo de documento, lista cerrada. identification cubre los documentos que identifican a la persona, como la cedula o la credencial de salud, que son distintos de insurance, que es el documento del seguro.';


--
-- Name: COLUMN medical_documents.title; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.title IS 'Titulo con que se muestra el documento. No puede quedar vacio.';


--
-- Name: COLUMN medical_documents.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.description IS 'Detalle opcional del contenido.';


--
-- Name: COLUMN medical_documents.document_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.document_date IS 'Fecha del documento en si, distinta de la fecha de subida.';


--
-- Name: COLUMN medical_documents.issued_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.issued_by IS 'Profesional o institucion que emitio el documento, como texto.';


--
-- Name: COLUMN medical_documents.added_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.added_by IS 'Usuario que incorporo el documento al expediente.';


--
-- Name: COLUMN medical_documents.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.deleted_at IS 'Momento de la baja logica. La fila se conserva (RF-43).';


--
-- Name: COLUMN medical_documents.deleted_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.deleted_by IS 'Usuario que dio de baja el documento.';


--
-- Name: COLUMN medical_documents.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN medical_documents.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medical_documents.updated_at IS 'Fecha de la ultima modificacion del registro.';


--
-- Name: medication_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.medication_days (
    medication_id uuid NOT NULL,
    day_of_week smallint NOT NULL,
    CONSTRAINT ck_medication_days_range CHECK (((day_of_week >= 1) AND (day_of_week <= 7)))
);


--
-- Name: TABLE medication_days; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.medication_days IS 'Días de la semana habilitados para cada medicamento. Normalización 1FN: reemplaza el arreglo JSON days_of_week de medications. PK compuesta (medication_id, day_of_week): cada fila es atómica.';


--
-- Name: COLUMN medication_days.day_of_week; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medication_days.day_of_week IS '1 = lunes, 2 = martes, …, 7 = domingo. ISO 8601. Sin fila = ese día no se administra.';


--
-- Name: medication_times; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.medication_times (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    medication_id uuid NOT NULL,
    time_of_day time without time zone NOT NULL
);


--
-- Name: TABLE medication_times; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.medication_times IS 'Horarios de toma de cada medicamento. Normalización 1FN: reemplaza el arreglo JSON times de medications. Cada fila = un horario atómico (HH:MM).';


--
-- Name: COLUMN medication_times.time_of_day; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medication_times.time_of_day IS 'Hora de toma en la zona horaria del paciente (patients.timezone). Tipo TIME sin zona: la conversión la aplica el job al generar scheduled_doses.';


--
-- Name: medications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.medications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    name character varying(120) NOT NULL,
    dose_amount numeric(8,2) NOT NULL,
    dose_unit character varying(20) NOT NULL,
    dose_text character varying(60) GENERATED ALWAYS AS ((((trim_scale(dose_amount))::text || ' '::text) || (dose_unit)::text)) STORED,
    instructions text,
    start_date date NOT NULL,
    end_date date,
    grace_window_min smallint DEFAULT 60 NOT NULL,
    prescribed_by uuid,
    discontinued_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_medications_dates CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT ck_medications_dose_amount CHECK ((dose_amount > (0)::numeric)),
    CONSTRAINT ck_medications_dose_unit CHECK (((dose_unit)::text = ANY ((ARRAY['mg'::character varying, 'g'::character varying, 'ml'::character varying, 'mcg'::character varying, 'UI'::character varying, 'gotas'::character varying, 'comprimido'::character varying, 'cápsula'::character varying, 'puff'::character varying, 'parche'::character varying])::text[]))),
    CONSTRAINT ck_medications_grace CHECK (((grace_window_min >= 5) AND (grace_window_min <= 720))),
    CONSTRAINT ck_medications_name_min CHECK ((char_length((name)::text) >= 2))
);


--
-- Name: TABLE medications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.medications IS 'Plan de medicamentos: QUÉ se administra y CON QUÉ FRECUENCIA. Las tomas concretas se materializan en scheduled_doses. Los horarios y días viven en medication_times y medication_days (1FN).';


--
-- Name: COLUMN medications.dose_amount; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medications.dose_amount IS 'Cantidad numérica de la dosis (p. ej. 50). Separada de la unidad para poder validar y comparar; antes era un varchar "50 mg" no computable.';


--
-- Name: COLUMN medications.dose_unit; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medications.dose_unit IS 'Unidad de la dosis: mg | g | ml | mcg | UI | gotas | comprimido | cápsula | puff | parche.';


--
-- Name: COLUMN medications.dose_text; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medications.dose_text IS 'Presentación generada (dose_amount + dose_unit) para la interfaz. Solo lectura.';


--
-- Name: COLUMN medications.grace_window_min; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medications.grace_window_min IS 'Minutos de tolerancia tras la hora programada antes de marcar la dosis como omitida y alertar (Anexo B).';


--
-- Name: COLUMN medications.prescribed_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medications.prescribed_by IS 'Quién definió el plan: médico o cuidadora (RF-24). ON DELETE RESTRICT: el plan y su responsable se conservan.';


--
-- Name: COLUMN medications.discontinued_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.medications.discontinued_at IS 'Descontinuación. Cancela las tomas futuras y conserva el historial (RF-27). NULL = vigente.';


--
-- Name: message_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id uuid NOT NULL,
    recipient_id uuid NOT NULL,
    delivered_at timestamp with time zone,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: TABLE message_receipts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.message_receipts IS 'Estado de entrega y lectura de mensajes por cada destinatario del círculo de cuidado.';


--
-- Name: COLUMN message_receipts.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.message_receipts.id IS 'Identificador único del acuse de recibo.';


--
-- Name: COLUMN message_receipts.message_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.message_receipts.message_id IS 'Mensaje asociado al acuse.';


--
-- Name: COLUMN message_receipts.recipient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.message_receipts.recipient_id IS 'Usuario destinatario del mensaje.';


--
-- Name: COLUMN message_receipts.delivered_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.message_receipts.delivered_at IS 'Fecha y hora en que el mensaje fue entregado al dispositivo.';


--
-- Name: COLUMN message_receipts.read_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.message_receipts.read_at IS 'Fecha y hora en que el mensaje fue leído por el usuario.';


--
-- Name: COLUMN message_receipts.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.message_receipts.created_at IS 'Fecha y hora de creación del registro.';


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    conversation_id uuid NOT NULL,
    sender_id uuid NOT NULL,
    kind character varying(20) DEFAULT 'text'::character varying NOT NULL,
    body text,
    file_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_messages_content CHECK (((((kind)::text = 'text'::text) AND (btrim(body) <> ''::text)) OR (((kind)::text = ANY ((ARRAY['voice'::character varying, 'photo'::character varying])::text[])) AND (file_id IS NOT NULL)))),
    CONSTRAINT chk_messages_kind CHECK (((kind)::text = ANY ((ARRAY['text'::character varying, 'voice'::character varying, 'photo'::character varying])::text[])))
);


--
-- Name: TABLE messages; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.messages IS 'Mensajes individuales (texto, voz, foto) transmitidos en una conversación.';


--
-- Name: COLUMN messages.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.messages.id IS 'Identificador único del mensaje.';


--
-- Name: COLUMN messages.conversation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.messages.conversation_id IS 'Conversación a la que pertenece el mensaje.';


--
-- Name: COLUMN messages.sender_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.messages.sender_id IS 'Usuario autor del mensaje.';


--
-- Name: COLUMN messages.kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.messages.kind IS 'Formato del mensaje: text, voice, photo.';


--
-- Name: COLUMN messages.body; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.messages.body IS 'Contenido textual del mensaje (no vacío tras trim).';


--
-- Name: COLUMN messages.file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.messages.file_id IS 'Referencia al archivo adjunto en la tabla files (para voz o foto).';


--
-- Name: COLUMN messages.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.messages.created_at IS 'Fecha y hora de envío del mensaje.';


--
-- Name: music_creations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.music_creations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    title character varying(150) NOT NULL,
    file_id uuid NOT NULL,
    duration_seconds integer NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    client_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT chk_music_creations_duration CHECK ((duration_seconds > 0))
);


--
-- Name: TABLE music_creations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.music_creations IS 'Creaciones musicales grabadas o compuestas por el adulto mayor mediante la app.';


--
-- Name: COLUMN music_creations.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.id IS 'Identificador único de la creación musical.';


--
-- Name: COLUMN music_creations.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.patient_id IS 'Paciente creador de la pieza musical.';


--
-- Name: COLUMN music_creations.created_by_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.created_by_user_id IS 'Usuario creador (adulto mayor).';


--
-- Name: COLUMN music_creations.title; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.title IS 'Título otorgado a la creación musical.';


--
-- Name: COLUMN music_creations.file_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.file_id IS 'Referencia al archivo de audio almacenado en files.';


--
-- Name: COLUMN music_creations.duration_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.duration_seconds IS 'Duración de la pista grabada en segundos.';


--
-- Name: COLUMN music_creations.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.deleted_at IS 'Fecha y hora de eliminación lógica.';


--
-- Name: COLUMN music_creations.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.created_at IS 'Fecha y hora de creación.';


--
-- Name: COLUMN music_creations.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.updated_at IS 'Fecha y hora de actualización.';


--
-- Name: COLUMN music_creations.client_uuid; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.music_creations.client_uuid IS 'Identificador que genera el dispositivo antes de subir la creación. UNIQUE: si la subida se reintenta porque se cortó la señal, el motor rechaza el duplicado. Es lo que cumple el "sin duplicar" de RF-66.';


--
-- Name: notification_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    alert_type character varying(20) NOT NULL,
    push_enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_notification_settings_critical_locked CHECK ((push_enabled OR ((alert_type)::text <> ALL ((ARRAY['fall'::character varying, 'sos'::character varying])::text[])))),
    CONSTRAINT ck_notification_settings_type CHECK (((alert_type)::text = ANY ((ARRAY['fall'::character varying, 'vital_out_of_range'::character varying, 'missed_dose'::character varying, 'sos'::character varying, 'wearable_offline'::character varying, 'incident'::character varying])::text[])))
);


--
-- Name: TABLE notification_settings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.notification_settings IS 'Preferencias de notificación por usuario y tipo de alerta (endpoints 9.4 y 9.5).';


--
-- Name: CONSTRAINT ck_notification_settings_critical_locked ON notification_settings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON CONSTRAINT ck_notification_settings_critical_locked ON public.notification_settings IS 'Las alertas de caída y SOS no se pueden desactivar (RF-50). La restricción vive en la base, no solo en la interfaz.';


--
-- Name: password_reset_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.password_reset_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token_hash character varying(64) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    attempts smallint DEFAULT 0 NOT NULL,
    CONSTRAINT ck_password_reset_tokens_attempts CHECK ((attempts >= 0)),
    CONSTRAINT ck_password_reset_tokens_vence CHECK ((expires_at > created_at))
);


--
-- Name: TABLE password_reset_tokens; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.password_reset_tokens IS 'Tokens de un solo uso para recuperar la contraseña (RF-05). Se guarda el hash; el token en claro solo viaja en el correo.';


--
-- Name: COLUMN password_reset_tokens.token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.password_reset_tokens.token_hash IS 'SHA-256 de "user_id:código". El código en claro solo viaja en el correo.';


--
-- Name: COLUMN password_reset_tokens.used_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.password_reset_tokens.used_at IS 'Momento en que se usó. NULL = aún válido (si tampoco venció).';


--
-- Name: COLUMN password_reset_tokens.attempts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.password_reset_tokens.attempts IS 'Códigos equivocados ingresados contra esta fila. Al llegar a password_reset_max_attempts la fila se marca usada.';


--
-- Name: patient_allergies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.patient_allergies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    substance character varying(80) NOT NULL,
    category character varying(20) DEFAULT 'otra'::character varying NOT NULL,
    severity character varying(20) DEFAULT 'moderada'::character varying NOT NULL,
    reaction character varying(200),
    source character varying(20) DEFAULT 'reportada'::character varying NOT NULL,
    noted_on date DEFAULT CURRENT_DATE NOT NULL,
    recorded_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_patient_allergies_category CHECK (((category)::text = ANY ((ARRAY['medicamento'::character varying, 'alimento'::character varying, 'ambiental'::character varying, 'otra'::character varying])::text[]))),
    CONSTRAINT ck_patient_allergies_severity CHECK (((severity)::text = ANY ((ARRAY['leve'::character varying, 'moderada'::character varying, 'severa'::character varying, 'anafilaxia'::character varying])::text[]))),
    CONSTRAINT ck_patient_allergies_source CHECK (((source)::text = ANY ((ARRAY['reportada'::character varying, 'test'::character varying, 'reaccion_tratamiento'::character varying])::text[])))
);


--
-- Name: TABLE patient_allergies; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.patient_allergies IS 'Alergias/intolerancias vigentes del paciente. Lista que crece en el tiempo (al registrar, por test, o por reacción en tratamiento). Baja lógica para histórico. severity leve|moderada|severa|anafilaxia. source reportada|test|reaccion_tratamiento. Las de categoría medicamento se cruzan con drug_catalog para advertir en la prescripción.';


--
-- Name: COLUMN patient_allergies.substance; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_allergies.substance IS 'Code del allergen_catalog o texto libre si no está catalogado.';


--
-- Name: COLUMN patient_allergies.source; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_allergies.source IS 'Cómo se supo: reportada (la dice el paciente/familia) | test (test de alergias) | reaccion_tratamiento (apareció durante un tratamiento).';


--
-- Name: COLUMN patient_allergies.noted_on; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_allergies.noted_on IS 'Fecha en que se descubrió/registró la alergia (distinta de created_at).';


--
-- Name: patient_conditions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.patient_conditions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    condition character varying(80) NOT NULL,
    diagnosed_at date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    system character varying(20) DEFAULT 'otras'::character varying NOT NULL,
    CONSTRAINT ck_patient_condition_min CHECK ((char_length((condition)::text) >= 2)),
    CONSTRAINT ck_patient_conditions_system CHECK (((system)::text = ANY ((ARRAY['cardiovascular'::character varying, 'respiratorio'::character varying, 'geriatrico'::character varying, 'metabolico'::character varying, 'osteomuscular'::character varying, 'neuropsiquiatrico'::character varying, 'sensorial'::character varying, 'otras'::character varying])::text[])))
);


--
-- Name: TABLE patient_conditions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.patient_conditions IS 'Condiciones médicas del paciente. Normalización 1FN: reemplaza el arreglo JSON conditions que vivía en patients. Permite filtrar pacientes por padecimiento y agregar fecha de diagnóstico.';


--
-- Name: COLUMN patient_conditions.condition; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_conditions.condition IS 'Código o descripción del padecimiento (ej. hipertension, diabetes_tipo_2).';


--
-- Name: COLUMN patient_conditions.diagnosed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_conditions.diagnosed_at IS 'Fecha de diagnóstico. Opcional; no estaba disponible en el modelo anterior.';


--
-- Name: COLUMN patient_conditions.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_conditions.deleted_at IS 'Baja lógica. Una condición corregida o remitida se desactiva; el histórico clínico se conserva para trazabilidad y analítica.';


--
-- Name: COLUMN patient_conditions.system; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_conditions.system IS 'Sistema/grupo clínico de la condición (cardiovascular, respiratorio, geriatrico, metabolico, osteomuscular, neuropsiquiatrico, sensorial, otras). Permite agrupar la ficha como el EMPAM. Default otras para texto libre.';


--
-- Name: patient_immunizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.patient_immunizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    vaccine character varying(30) NOT NULL,
    kind character varying(20) DEFAULT 'preventiva'::character varying NOT NULL,
    administered_on date,
    next_due_on date,
    dose_number smallint,
    exposure_event character varying(200),
    note character varying(200),
    recorded_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_patient_immunizations_alguna_fecha CHECK (((administered_on IS NOT NULL) OR (next_due_on IS NOT NULL))),
    CONSTRAINT ck_patient_immunizations_dose CHECK (((dose_number IS NULL) OR (dose_number > 0))),
    CONSTRAINT ck_patient_immunizations_kind CHECK (((kind)::text = ANY ((ARRAY['preventiva'::character varying, 'post_exposicion'::character varying])::text[])))
);


--
-- Name: TABLE patient_immunizations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.patient_immunizations IS 'Vacunas aplicadas o programadas al paciente (carnet de inmunizaciones). FK a vaccine_catalog (fuente única de verdad). Baja lógica para conservar el histórico. Las preventivas recurrentes calculan next_due_on; las de post-exposición registran el evento que las gatilló.';


--
-- Name: COLUMN patient_immunizations.vaccine; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_immunizations.vaccine IS 'Vacuna. FK a vaccine_catalog.code (catálogo centralizado). Reemplaza un CHECK de lista duplicada.';


--
-- Name: COLUMN patient_immunizations.kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_immunizations.kind IS 'Naturaleza de esta dosis: preventiva | post_exposicion. Por defecto hereda la del catálogo; explícita por si un caso difiere.';


--
-- Name: COLUMN patient_immunizations.administered_on; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_immunizations.administered_on IS 'Fecha de administración (hecho clínico). NULL cuando la dosis está solo programada/pendiente.';


--
-- Name: COLUMN patient_immunizations.next_due_on; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_immunizations.next_due_on IS 'Próxima dosis recomendada (solo preventivas recurrentes). Calculada por la app con vaccine_catalog.interval_months; se persiste para ordenar recordatorios.';


--
-- Name: COLUMN patient_immunizations.exposure_event; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_immunizations.exposure_event IS 'Solo post-exposición: descripción del hecho que gatilló la vacuna (ej. "mordedura de perro callejero").';


--
-- Name: patient_measurements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.patient_measurements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    weight_kg numeric(5,2),
    height_cm numeric(5,1),
    measured_at date DEFAULT CURRENT_DATE NOT NULL,
    recorded_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_patient_measurements_algo CHECK (((weight_kg IS NOT NULL) OR (height_cm IS NOT NULL))),
    CONSTRAINT ck_patient_measurements_height CHECK (((height_cm IS NULL) OR ((height_cm > (0)::numeric) AND (height_cm <= (260)::numeric)))),
    CONSTRAINT ck_patient_measurements_weight CHECK (((weight_kg IS NULL) OR ((weight_kg > (0)::numeric) AND (weight_kg <= (400)::numeric))))
);


--
-- Name: TABLE patient_measurements; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.patient_measurements IS 'Mediciones antropométricas del paciente con historial (peso, altura). El IMC se calcula al mostrar (peso/altura²), no se almacena. El peso cambia en el tiempo: por eso es tabla y no columna de patients.';


--
-- Name: COLUMN patient_measurements.measured_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_measurements.measured_at IS 'Fecha de la medición (del control), distinta de created_at.';


--
-- Name: COLUMN patient_measurements.recorded_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_measurements.recorded_by IS 'Quién registró la medición (profesional o cuidadora).';


--
-- Name: patient_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.patient_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    is_owner boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    removed_at timestamp with time zone,
    profession character varying(30),
    relationship character varying(20),
    CONSTRAINT ck_patient_members_owner_is_family CHECK (((NOT is_owner) OR ((role)::text = 'family'::text))),
    CONSTRAINT ck_patient_members_profession CHECK (((profession IS NULL) OR ((profession)::text = ANY ((ARRAY['medico_general'::character varying, 'medico_especialista'::character varying, 'kinesiologo'::character varying, 'enfermera'::character varying, 'podologa'::character varying, 'nutricionista'::character varying, 'fonoaudiologo'::character varying, 'terapeuta_ocupacional'::character varying, 'psicologo'::character varying, 'trabajador_social'::character varying, 'cuidadora'::character varying, 'familiar'::character varying])::text[])))),
    CONSTRAINT ck_patient_members_relationship CHECK (((relationship IS NULL) OR ((relationship)::text = ANY ((ARRAY['hijo'::character varying, 'hija'::character varying, 'conyuge'::character varying, 'hermano'::character varying, 'hermana'::character varying, 'nieto'::character varying, 'nieta'::character varying, 'sobrino'::character varying, 'sobrina'::character varying, 'yerno'::character varying, 'nuera'::character varying, 'cuidador'::character varying, 'otro'::character varying])::text[])))),
    CONSTRAINT ck_patient_members_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[])))
);


--
-- Name: TABLE patient_members; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.patient_members IS 'Vínculo entre usuarios y pacientes, con el rol de cada uno. Es el centro del control de acceso: ninguna consulta al expediente se ejecuta sin verificarla primero.';


--
-- Name: COLUMN patient_members.role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_members.role IS 'Rol DE LA RELACIÓN, no de la persona: family | caregiver | doctor | elder. El mismo usuario puede tener roles distintos sobre pacientes distintos.';


--
-- Name: COLUMN patient_members.is_owner; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_members.is_owner IS 'Familiar administrador del paciente. Lo crea el endpoint 4.1 y no puede ser eliminado (endpoint 4.8). Solo un rol family puede serlo.';


--
-- Name: COLUMN patient_members.removed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_members.removed_at IS 'Baja del círculo de cuidado. Se conserva la fila porque el endpoint 14.4 exige saber quién estuvo alguna vez en el círculo para validar las reseñas.';


--
-- Name: COLUMN patient_members.profession; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_members.profession IS 'Rol clínico real del miembro (medico_general, kinesiologo, enfermera, podologa, ...). role sigue siendo el PERMISO (family/caregiver/doctor/elder); profession es la etiqueta del equipo tratante. NULL si no aplica.';


--
-- Name: COLUMN patient_members.relationship; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patient_members.relationship IS 'Parentesco del miembro con el paciente (hijo, hija, cónyuge, hermano...). NULL para quienes no son familia (ej. médico contratado). Distinto de profession (rol clínico).';


--
-- Name: patients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.patients (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    first_name character varying(60) NOT NULL,
    last_name character varying(60) NOT NULL,
    rut_number integer,
    rut_dv character(1),
    birth_date date NOT NULL,
    sex character(1) NOT NULL,
    photo_url text,
    timezone character varying(50) DEFAULT 'America/Santiago'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    address character varying(200),
    marital_status character varying(20),
    insurance character varying(20),
    rcv_level character varying(10),
    complexity character varying(15),
    priority character varying(10),
    second_name character varying(60),
    second_last_name character varying(60),
    full_name character varying(250) GENERATED ALWAYS AS ((((((first_name)::text || COALESCE((' '::text || (second_name)::text), ''::text)) || ' '::text) || (last_name)::text) || COALESCE((' '::text || (second_last_name)::text), ''::text))) STORED,
    CONSTRAINT ck_patients_birth_date CHECK (((birth_date > '1900-01-01'::date) AND (birth_date <= CURRENT_DATE))),
    CONSTRAINT ck_patients_complexity CHECK (((complexity IS NULL) OR ((complexity)::text = ANY ((ARRAY['baja'::character varying, 'moderada'::character varying, 'alta'::character varying])::text[])))),
    CONSTRAINT ck_patients_first_name_min CHECK ((char_length((first_name)::text) >= 1)),
    CONSTRAINT ck_patients_insurance CHECK (((insurance IS NULL) OR ((insurance)::text = ANY ((ARRAY['fonasa'::character varying, 'isapre'::character varying, 'particular'::character varying, 'otra'::character varying])::text[])))),
    CONSTRAINT ck_patients_last_name_min CHECK ((char_length((last_name)::text) >= 1)),
    CONSTRAINT ck_patients_marital_status CHECK (((marital_status IS NULL) OR ((marital_status)::text = ANY ((ARRAY['soltero'::character varying, 'casado'::character varying, 'viudo'::character varying, 'divorciado'::character varying, 'conviviente'::character varying, 'separado'::character varying])::text[])))),
    CONSTRAINT ck_patients_priority CHECK (((priority IS NULL) OR ((priority)::text = ANY ((ARRAY['baja'::character varying, 'media'::character varying, 'alta'::character varying])::text[])))),
    CONSTRAINT ck_patients_rcv_level CHECK (((rcv_level IS NULL) OR ((rcv_level)::text = ANY ((ARRAY['bajo'::character varying, 'moderado'::character varying, 'alto'::character varying])::text[])))),
    CONSTRAINT ck_patients_rut_dv CHECK (((rut_dv IS NULL) OR (rut_dv ~ '^[0-9K]$'::text))),
    CONSTRAINT ck_patients_rut_dv_correcto CHECK (((rut_number IS NULL) OR (rut_dv = public.rut_digito_verificador(rut_number)))),
    CONSTRAINT ck_patients_rut_number CHECK (((rut_number IS NULL) OR ((rut_number >= 1000000) AND (rut_number <= 99999999)))),
    CONSTRAINT ck_patients_rut_pair CHECK (((rut_number IS NULL) = (rut_dv IS NULL))),
    CONSTRAINT ck_patients_second_last_name CHECK (((second_last_name IS NULL) OR (char_length(btrim((second_last_name)::text)) >= 1))),
    CONSTRAINT ck_patients_second_name CHECK (((second_name IS NULL) OR (char_length(btrim((second_name)::text)) >= 1))),
    CONSTRAINT ck_patients_sex CHECK ((sex = ANY (ARRAY['M'::bpchar, 'F'::bpchar, 'O'::bpchar])))
);


--
-- Name: TABLE patients; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.patients IS 'Adultos mayores de los que se lleva expediente. NO es un usuario: el paciente puede no tener cuenta. El vínculo entre personas y pacientes vive en patient_members.';


--
-- Name: COLUMN patients.first_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.first_name IS 'Nombre(s) del adulto mayor. Separado de last_name para ordenar por apellido y generar saludos formales. 1FN: atomicidad.';


--
-- Name: COLUMN patients.last_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.last_name IS 'Apellido(s) del adulto mayor. 1FN: atributo distinto de first_name.';


--
-- Name: COLUMN patients.rut_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.rut_number IS 'Número del RUT sin puntos ni dígito verificador. Entero para evitar duplicados por formato.';


--
-- Name: COLUMN patients.rut_dv; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.rut_dv IS 'Dígito verificador del RUT. Es un dato DERIVADO de rut_number por el módulo 11, y un CHECK contra rut_digito_verificador() impide que quede inconsistente. Se almacena para poder mostrarlo y buscarlo sin recalcular.';


--
-- Name: COLUMN patients.birth_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.birth_date IS 'Fecha de nacimiento. La edad se calcula: date_part(''year'', age(birth_date)).';


--
-- Name: COLUMN patients.sex; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.sex IS 'M = masculino, F = femenino, O = otro.';


--
-- Name: COLUMN patients.timezone; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.timezone IS 'Zona horaria IANA. Base del cálculo de horarios de medicación (RF-32). Por defecto America/Santiago.';


--
-- Name: COLUMN patients.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.deleted_at IS 'Baja lógica. El expediente clínico nunca se borra físicamente.';


--
-- Name: COLUMN patients.address; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.address IS 'Domicilio del paciente (texto). Para visitas y derivaciones.';


--
-- Name: COLUMN patients.marital_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.marital_status IS 'Estado civil. Lista cerrada. Puede quedar NULL.';


--
-- Name: COLUMN patients.insurance; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.insurance IS 'Previsión de salud: fonasa | isapre | particular | otra.';


--
-- Name: COLUMN patients.rcv_level; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.rcv_level IS 'Nivel de riesgo cardiovascular (MINSAL 2014): bajo | moderado | alto. Define metas terapéuticas. NULL = no evaluado.';


--
-- Name: COLUMN patients.complexity; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.complexity IS 'Nivel de complejidad del paciente: baja | moderada | alta. Un crónico de alta complejidad requiere seguimiento estrecho. NULL = no evaluado.';


--
-- Name: COLUMN patients.priority; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.priority IS 'Prioridad de atención/vigilancia del paciente: baja | media | alta. Distinta de complexity (carga clínica): un alta complejidad controlado puede ser baja prioridad. NULL = no evaluada.';


--
-- Name: COLUMN patients.second_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.second_name IS 'Segundo nombre. Opcional: no toda persona lo tiene.';


--
-- Name: COLUMN patients.second_last_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.second_last_name IS 'Segundo apellido (materno). Opcional: no toda persona lo tiene.';


--
-- Name: COLUMN patients.full_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.patients.full_name IS 'Columna generada: nombre, segundo nombre, apellido y segundo apellido, sin huecos. Solo lectura.';


--
-- Name: photo_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.photo_reactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    photo_id uuid NOT NULL,
    user_id uuid NOT NULL,
    reaction_type character varying(20) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_photo_reactions_type CHECK (((reaction_type)::text = ANY ((ARRAY['like'::character varying, 'love'::character varying, 'smile'::character varying, 'heart'::character varying])::text[])))
);


--
-- Name: TABLE photo_reactions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.photo_reactions IS 'Reacciones registradas por el adulto mayor u otros miembros sobre las fotos de la galería.';


--
-- Name: COLUMN photo_reactions.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.photo_reactions.id IS 'Identificador único de la reacción.';


--
-- Name: COLUMN photo_reactions.photo_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.photo_reactions.photo_id IS 'Fotografía de la galería reaccionada.';


--
-- Name: COLUMN photo_reactions.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.photo_reactions.user_id IS 'Usuario que emite la reacción (usualmente el adulto mayor).';


--
-- Name: COLUMN photo_reactions.reaction_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.photo_reactions.reaction_type IS 'Tipo de reacción emotiva: like, love, smile, heart.';


--
-- Name: COLUMN photo_reactions.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.photo_reactions.created_at IS 'Fecha y hora de registro de la reacción.';


--
-- Name: plan_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plan_features (
    plan_id uuid NOT NULL,
    feature_code character varying(40) NOT NULL,
    is_included boolean DEFAULT true NOT NULL,
    note character varying(200),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE plan_features; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.plan_features IS 'Relacion entre planes y funcionalidades. Define que incluye cada plan y es lo que responde si una funcion esta habilitada. RF-73, RF-83 a RF-85.';


--
-- Name: COLUMN plan_features.plan_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_features.plan_id IS 'Plan al que se le asigna la funcionalidad.';


--
-- Name: COLUMN plan_features.feature_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_features.feature_code IS 'Funcionalidad asignada.';


--
-- Name: COLUMN plan_features.is_included; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_features.is_included IS 'Verdadero si el plan incluye la funcionalidad. Falso permite excluirla de forma explicita.';


--
-- Name: COLUMN plan_features.note; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_features.note IS 'Aclaracion sobre el alcance con que se incluye, si corresponde.';


--
-- Name: COLUMN plan_features.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_features.created_at IS 'Fecha de creacion del registro.';


--
-- Name: plan_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plan_limits (
    plan_id uuid NOT NULL,
    limit_key character varying(40) NOT NULL,
    limit_value integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_plan_limits_value CHECK (((limit_value IS NULL) OR (limit_value >= 0)))
);


--
-- Name: TABLE plan_limits; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.plan_limits IS 'Valor de cada límite para cada plan. Cumple 2FN: limit_value depende de la clave completa (plan_id, limit_key). La unidad se movió a limit_keys porque dependía solo del límite. RF-73, RF-83 a RF-85.';


--
-- Name: COLUMN plan_limits.plan_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_limits.plan_id IS 'Plan al que aplica el limite.';


--
-- Name: COLUMN plan_limits.limit_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_limits.limit_key IS 'Límite que se está fijando. Apunta al catálogo limit_keys.';


--
-- Name: COLUMN plan_limits.limit_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_limits.limit_value IS 'Valor del limite. Nulo significa sin limite.';


--
-- Name: COLUMN plan_limits.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_limits.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN plan_limits.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_limits.updated_at IS 'Fecha de la ultima modificacion del registro.';


--
-- Name: plan_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plan_prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_id uuid NOT NULL,
    currency character(3) DEFAULT 'CLP'::bpchar NOT NULL,
    period character varying(10) NOT NULL,
    amount numeric(12,2) NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_to timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_plan_prices_amount CHECK ((amount >= (0)::numeric)),
    CONSTRAINT ck_plan_prices_currency CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT ck_plan_prices_period CHECK (((period)::text = ANY ((ARRAY['monthly'::character varying, 'yearly'::character varying, 'once'::character varying])::text[]))),
    CONSTRAINT ck_plan_prices_vigencia CHECK (((valid_to IS NULL) OR (valid_to > valid_from)))
);


--
-- Name: TABLE plan_prices; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.plan_prices IS 'Historial de precios de cada plan con vigencia. Una restriccion de exclusion impide dos precios vigentes a la vez para el mismo plan, moneda y periodo. RF-83 a RF-85.';


--
-- Name: COLUMN plan_prices.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.id IS 'Identificador del precio.';


--
-- Name: COLUMN plan_prices.plan_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.plan_id IS 'Plan al que corresponde el precio.';


--
-- Name: COLUMN plan_prices.currency; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.currency IS 'Moneda en codigo ISO de tres letras. Por omision CLP.';


--
-- Name: COLUMN plan_prices.period; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.period IS 'Periodo de cobro: monthly, yearly u once.';


--
-- Name: COLUMN plan_prices.amount; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.amount IS 'Monto del plan en la moneda indicada.';


--
-- Name: COLUMN plan_prices.valid_from; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.valid_from IS 'Inicio de vigencia del precio.';


--
-- Name: COLUMN plan_prices.valid_to; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.valid_to IS 'Fin de vigencia. Nulo significa que es el precio actual.';


--
-- Name: COLUMN plan_prices.created_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.created_by IS 'Usuario que definio el precio.';


--
-- Name: COLUMN plan_prices.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plan_prices.created_at IS 'Fecha de creacion del registro.';


--
-- Name: plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(60) NOT NULL,
    description character varying(300),
    tier smallint NOT NULL,
    is_public boolean DEFAULT true NOT NULL,
    status character varying(12) DEFAULT 'draft'::character varying NOT NULL,
    created_by uuid,
    published_at timestamp with time zone,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_plans_code CHECK (((code)::text ~ '^[a-z][a-z0-9_]{2,19}$'::text)),
    CONSTRAINT ck_plans_name CHECK ((btrim((name)::text) <> ''::text)),
    CONSTRAINT ck_plans_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'archived'::character varying])::text[]))),
    CONSTRAINT ck_plans_status_fechas CHECK (((((status)::text = 'draft'::text) AND (published_at IS NULL) AND (archived_at IS NULL)) OR (((status)::text = 'active'::text) AND (published_at IS NOT NULL) AND (archived_at IS NULL)) OR (((status)::text = 'archived'::text) AND (published_at IS NOT NULL) AND (archived_at IS NOT NULL)))),
    CONSTRAINT ck_plans_tier CHECK (((tier >= 0) AND (tier <= 10)))
);


--
-- Name: TABLE plans; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.plans IS 'Planes comerciales de AgeCare. Tienen ciclo de vida (borrador, activo, archivado) y nunca se borran porque hay suscripciones e historial de cobros que los referencian. RF-83 a RF-85.';


--
-- Name: COLUMN plans.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.id IS 'Identificador del plan.';


--
-- Name: COLUMN plans.code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.code IS 'Codigo estable del plan, por ejemplo free o premium.';


--
-- Name: COLUMN plans.name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.name IS 'Nombre comercial que ve el usuario.';


--
-- Name: COLUMN plans.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.description IS 'Descripcion del plan para la pantalla de contratacion.';


--
-- Name: COLUMN plans.tier; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.tier IS 'Jerarquia del plan. Cero es el plan gratuito.';


--
-- Name: COLUMN plans.is_public; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.is_public IS 'Verdadero si el plan se ofrece abiertamente. Falso para planes internos o a medida.';


--
-- Name: COLUMN plans.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.status IS 'Estado del plan: draft, active o archived. Archivado no se puede contratar.';


--
-- Name: COLUMN plans.created_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.created_by IS 'Usuario que creo el plan en el constructor.';


--
-- Name: COLUMN plans.published_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.published_at IS 'Momento en que el plan quedo disponible para contratar.';


--
-- Name: COLUMN plans.archived_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.archived_at IS 'Momento en que el plan dejo de ofrecerse.';


--
-- Name: COLUMN plans.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN plans.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.plans.updated_at IS 'Fecha de la ultima modificacion del registro.';


--
-- Name: push_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    push_token character varying(255) NOT NULL,
    platform character varying(10) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_push_devices_platform CHECK (((platform)::text = ANY ((ARRAY['ios'::character varying, 'android'::character varying, 'web'::character varying])::text[])))
);


--
-- Name: TABLE push_devices; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.push_devices IS 'Aparatos registrados para recibir notificaciones push. Sin esto, las alertas no llegan a nadie.';


--
-- Name: COLUMN push_devices.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.push_devices.user_id IS 'Dueño actual del aparato. Puede cambiar si otra persona inicia sesión en el mismo teléfono.';


--
-- Name: COLUMN push_devices.push_token; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.push_devices.push_token IS 'Código que entrega FCM o APNs. Identifica la instalación de la app, no a la persona. Único en toda la tabla.';


--
-- Name: COLUMN push_devices.platform; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.push_devices.platform IS 'Sistema del aparato: ios | android | web.';


--
-- Name: COLUMN push_devices.is_active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.push_devices.is_active IS 'false = se cerró sesión en ese aparato o el token dejó de ser válido. Se deja de enviar, pero no se borra.';


--
-- Name: COLUMN push_devices.last_seen_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.push_devices.last_seen_at IS 'Última vez que la app confirmó este aparato. Sirve para limpiar los abandonados.';


--
-- Name: COLUMN push_devices.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.push_devices.created_at IS 'Primer registro del aparato.';


--
-- Name: COLUMN push_devices.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.push_devices.updated_at IS 'Última modificación. Trigger tg_push_devices_updated_at agregado en corrección 2FN: faltaba en la versión original.';


--
-- Name: record_access_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
)
PARTITION BY RANGE (accessed_at);


--
-- Name: TABLE record_access_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.record_access_log IS 'Registro de cada consulta al expediente de un paciente. Append-only y particionado por mes. Responde quien vio que y cuando. RNF-14.';


--
-- Name: COLUMN record_access_log.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.id IS 'Identificador del acceso.';


--
-- Name: COLUMN record_access_log.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.patient_id IS 'Expediente consultado.';


--
-- Name: COLUMN record_access_log.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.user_id IS 'Usuario que consulto.';


--
-- Name: COLUMN record_access_log.role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.role IS 'Rol con que accedio, congelado al momento del acceso. No se recalcula si el rol cambia despues.';


--
-- Name: COLUMN record_access_log.section; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.section IS 'Parte del expediente consultada: profile | vitals | medications | doses | logbook | documents | alerts | chat | reports | members | assistant | music. ''assistant'' es una pregunta al asistente de IA; ''music'' son las creaciones del Director Musical.';


--
-- Name: COLUMN record_access_log.entity_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.entity_id IS 'Registro puntual consultado dentro de la seccion, cuando aplica.';


--
-- Name: COLUMN record_access_log.ip_address; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.ip_address IS 'Direccion IP de origen.';


--
-- Name: COLUMN record_access_log.user_agent; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.user_agent IS 'Identificacion del cliente que hizo la consulta.';


--
-- Name: COLUMN record_access_log.accessed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.record_access_log.accessed_at IS 'Momento del acceso. Es la clave de particionado.';


--
-- Name: record_access_log_202610; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202610 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202611; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202611 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202612; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202612 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202701; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202701 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202702; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202702 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202703; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202703 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202704; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202704 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202705; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202705 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202706; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202706 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202707; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202707 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202708; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202708 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202709; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202709 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202710; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202710 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202711; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202711 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_202712; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_202712 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: record_access_log_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.record_access_log_default (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(10) NOT NULL,
    section character varying(24) NOT NULL,
    entity_id uuid,
    ip_address inet,
    user_agent character varying(300),
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_record_access_log_role CHECK (((role)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_record_access_log_section CHECK (((section)::text = ANY ((ARRAY['profile'::character varying, 'vitals'::character varying, 'medications'::character varying, 'doses'::character varying, 'logbook'::character varying, 'documents'::character varying, 'alerts'::character varying, 'chat'::character varying, 'reports'::character varying, 'members'::character varying, 'assistant'::character varying, 'music'::character varying])::text[])))
);


--
-- Name: refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refresh_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    family_id uuid NOT NULL,
    token_hash character varying(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    revoked_reason character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_refresh_tokens_expires CHECK ((expires_at > created_at)),
    CONSTRAINT ck_refresh_tokens_revoked_pair CHECK (((revoked_at IS NULL) = (revoked_reason IS NULL))),
    CONSTRAINT ck_refresh_tokens_revoked_reason CHECK (((revoked_reason IS NULL) OR ((revoked_reason)::text = ANY ((ARRAY['rotated'::character varying, 'logout'::character varying, 'reuse_detected'::character varying, 'password_reset'::character varying, 'account_disabled'::character varying])::text[]))))
);


--
-- Name: TABLE refresh_tokens; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.refresh_tokens IS 'Sesiones activas. Guarda el hash del refresh token para poder revocarlo desde el servidor, algo que el access token (JWT sin estado) no permite.';


--
-- Name: COLUMN refresh_tokens.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.id IS 'Identificador interno del registro de sesión.';


--
-- Name: COLUMN refresh_tokens.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.user_id IS 'Dueño de la sesión. ON DELETE RESTRICT: el modelo no admite borrado físico; una cuenta se desactiva, no se elimina.';


--
-- Name: COLUMN refresh_tokens.family_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.family_id IS 'Agrupa todos los tokens nacidos del mismo inicio de sesión. Permite revocar una sola sesión ante reutilización, sin desconectar los demás dispositivos (ticket AGE-104).';


--
-- Name: COLUMN refresh_tokens.token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.token_hash IS 'SHA-256 en hexadecimal del token. Nunca el token en claro. Hash rápido a propósito: el token es aleatorio de 256 bits, no necesita resistencia a fuerza bruta.';


--
-- Name: COLUMN refresh_tokens.expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.expires_at IS 'Vencimiento. 30 días desde la emisión, según la Documentación de Seguridad.';


--
-- Name: COLUMN refresh_tokens.revoked_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.revoked_at IS 'Momento de la revocación. NULL = vigente.';


--
-- Name: COLUMN refresh_tokens.revoked_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.revoked_reason IS 'Motivo: rotated | logout | reuse_detected | password_reset | account_disabled.';


--
-- Name: COLUMN refresh_tokens.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.refresh_tokens.created_at IS 'Momento de emisión del token.';


--
-- Name: scheduled_doses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scheduled_doses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    medication_id uuid,
    scheduled_at timestamp with time zone NOT NULL,
    status character varying(10) DEFAULT 'pending'::character varying NOT NULL,
    administered_at timestamp with time zone,
    logged_by uuid,
    logged_at timestamp with time zone,
    reason character varying(200),
    postponed_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    treatment_item_id uuid,
    CONSTRAINT ck_scheduled_doses_admin_order CHECK (((administered_at IS NULL) OR (administered_at >= scheduled_at))),
    CONSTRAINT ck_scheduled_doses_administered CHECK ((((status)::text <> ALL ((ARRAY['taken'::character varying, 'adverse'::character varying])::text[])) OR (administered_at IS NOT NULL))),
    CONSTRAINT ck_scheduled_doses_logged_pair CHECK (((logged_at IS NULL) = (logged_by IS NULL))),
    CONSTRAINT ck_scheduled_doses_logged_status CHECK ((((status)::text <> ALL ((ARRAY['taken'::character varying, 'skipped'::character varying, 'adverse'::character varying])::text[])) OR (logged_at IS NOT NULL))),
    CONSTRAINT ck_scheduled_doses_origen CHECK ((num_nonnulls(medication_id, treatment_item_id) = 1)),
    CONSTRAINT ck_scheduled_doses_postpone_limit CHECK (((postponed_until IS NULL) OR (postponed_until <= (scheduled_at + '04:00:00'::interval)))),
    CONSTRAINT ck_scheduled_doses_postponed CHECK ((((status)::text <> 'postponed'::text) OR (postponed_until IS NOT NULL))),
    CONSTRAINT ck_scheduled_doses_skip_reason CHECK ((((status)::text <> ALL ((ARRAY['skipped'::character varying, 'adverse'::character varying])::text[])) OR (reason IS NOT NULL))),
    CONSTRAINT ck_scheduled_doses_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'taken'::character varying, 'skipped'::character varying, 'postponed'::character varying, 'missed'::character varying, 'adverse'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: TABLE scheduled_doses; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.scheduled_doses IS 'Tomas concretas generadas a partir del plan (medications + medication_times + medication_days). Existen ANTES de ocurrir, lo que permite registrar ausencias y calcular adherencia: sin estas filas no habría denominador.';


--
-- Name: COLUMN scheduled_doses.scheduled_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.scheduled_at IS 'Momento en que la dosis DEBÍA administrarse (planificado por el job según el plan).';


--
-- Name: COLUMN scheduled_doses.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.status IS 'pending | taken | skipped | postponed | missed | adverse | cancelled. ''cancelled'' la pone el sistema cuando la toma deja de corresponder porque cambio o se descontinuo la indicacion (RF-26, RF-27): no es una toma omitida y no cuenta en la adherencia.';


--
-- Name: COLUMN scheduled_doses.administered_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.administered_at IS 'Momento REAL de administración al paciente (hecho clínico). Distinto de logged_at: una dosis puede darse a las 08:00 y registrarse a las 23:00. Base para medir puntualidad real, no solo adherencia administrativa.';


--
-- Name: COLUMN scheduled_doses.logged_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.logged_by IS 'Usuario que registró la dosis. Es la rendición de cuentas del acto: el sistema no puede validar la administración física, pero sí dejar evidencia inmutable de quién la declaró y cuándo.';


--
-- Name: COLUMN scheduled_doses.logged_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.logged_at IS 'Momento en que la cuidadora REGISTRÓ la dosis en la app (acto administrativo). Junto con logged_by da trazabilidad y responsabilidad del registro.';


--
-- Name: COLUMN scheduled_doses.reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.reason IS 'Motivo libre. Obligatorio en skipped y adverse. Es donde la cuidadora describe lo que realmente paso, sin una lista cerrada.';


--
-- Name: COLUMN scheduled_doses.postponed_until; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.postponed_until IS 'Nueva hora tras posponer. Máximo 4 horas después de lo programado (endpoint 6.6).';


--
-- Name: COLUMN scheduled_doses.treatment_item_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.scheduled_doses.treatment_item_id IS 'Indicacion de la que nace la dosis en el modelo de tratamientos (el oficial). Una dosis tiene EXACTAMENTE un origen: treatment_item_id en el modelo vigente, o medication_id en las dosis historicas del modelo viejo, nunca los dos (ck_scheduled_doses_origen).';


--
-- Name: shift_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shift_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    author_id uuid NOT NULL,
    shift_date date NOT NULL,
    shift character varying(10) NOT NULL,
    note character varying(2000) NOT NULL,
    handover_to uuid,
    acknowledged_by uuid,
    acknowledged_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_shift_notes_ack CHECK (((acknowledged_at IS NULL) = (acknowledged_by IS NULL))),
    CONSTRAINT ck_shift_notes_note CHECK ((btrim((note)::text) <> ''::text)),
    CONSTRAINT ck_shift_notes_shift CHECK (((shift)::text = ANY ((ARRAY['morning'::character varying, 'afternoon'::character varying, 'night'::character varying])::text[])))
);


--
-- Name: TABLE shift_notes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.shift_notes IS 'Notas de relevo que deja cada turno al siguiente. Una por paciente, fecha y turno. RF-37.';


--
-- Name: COLUMN shift_notes.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.id IS 'Identificador de la nota de relevo.';


--
-- Name: COLUMN shift_notes.patient_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.patient_id IS 'Paciente al que se refiere el relevo.';


--
-- Name: COLUMN shift_notes.author_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.author_id IS 'Usuario que entrega el turno y escribe la nota.';


--
-- Name: COLUMN shift_notes.shift_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.shift_date IS 'Fecha del turno que se esta entregando.';


--
-- Name: COLUMN shift_notes.shift; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.shift IS 'Turno entregado: morning, afternoon o night.';


--
-- Name: COLUMN shift_notes.note; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.note IS 'Contenido del relevo. No puede quedar vacio.';


--
-- Name: COLUMN shift_notes.handover_to; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.handover_to IS 'Usuario que recibe el turno, cuando se conoce de antemano.';


--
-- Name: COLUMN shift_notes.acknowledged_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.acknowledged_by IS 'Usuario que confirmo haber leido la nota.';


--
-- Name: COLUMN shift_notes.acknowledged_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.acknowledged_at IS 'Momento del acuse de lectura.';


--
-- Name: COLUMN shift_notes.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN shift_notes.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.updated_at IS 'Fecha de la ultima modificacion del registro.';


--
-- Name: COLUMN shift_notes.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.shift_notes.deleted_at IS 'Marca de baja. La fila se conserva, deja de mostrarse.';


--
-- Name: sos_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sos_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    triggered_by uuid,
    alert_id uuid NOT NULL,
    note character varying(300),
    latitude numeric(9,6),
    longitude numeric(9,6),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_sos_events_coords CHECK (((latitude IS NULL) = (longitude IS NULL))),
    CONSTRAINT ck_sos_events_lat CHECK (((latitude IS NULL) OR ((latitude >= ('-90'::integer)::numeric) AND (latitude <= (90)::numeric)))),
    CONSTRAINT ck_sos_events_lng CHECK (((longitude IS NULL) OR ((longitude >= ('-180'::integer)::numeric) AND (longitude <= (180)::numeric))))
);


--
-- Name: TABLE sos_events; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.sos_events IS 'Activaciones del botón de emergencia. Cada una genera exactamente una alerta crítica (UNIQUE sobre alert_id).';


--
-- Name: COLUMN sos_events.triggered_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sos_events.triggered_by IS 'Quién lo activó: cuidadora o el propio adulto mayor (RF-51). ON DELETE RESTRICT: el evento queda en el expediente.';


--
-- Name: COLUMN sos_events.latitude; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sos_events.latitude IS 'Ubicación al momento del SOS. No está en el Anexo A, pero la app la captura: el pubspec.yaml incluye geolocator con el comentario "ubicación para SOS".';


--
-- Name: specialties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.specialties (
    code character varying(40) NOT NULL,
    label character varying(80) NOT NULL,
    description character varying(300),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_specialties_code CHECK (((code)::text ~ '^[a-z][a-z0-9_]{2,39}$'::text)),
    CONSTRAINT ck_specialties_label CHECK ((btrim((label)::text) <> ''::text))
);


--
-- Name: TABLE specialties; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.specialties IS 'Catálogo de especialidades de cuidado. Fuente única de verdad para el filtro de búsqueda de cuidadoras. RF-72, RF-75.';


--
-- Name: COLUMN specialties.code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.specialties.code IS 'Código estable de la especialidad, por ejemplo alzheimer o movilidad_reducida. Es lo que consulta la aplicación.';


--
-- Name: COLUMN specialties.label; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.specialties.label IS 'Nombre visible de la especialidad.';


--
-- Name: COLUMN specialties.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.specialties.description IS 'Explicación de qué abarca la especialidad, para la pantalla de búsqueda.';


--
-- Name: COLUMN specialties.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.specialties.created_at IS 'Fecha de creación del registro.';


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    current_period_end timestamp with time zone,
    cancelled_at timestamp with time zone,
    provider_ref character varying(120),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    plan_id uuid,
    granted_by uuid,
    change_reason character varying(200),
    source character varying(10) DEFAULT 'purchase'::character varying NOT NULL,
    cancel_requested_at timestamp with time zone,
    CONSTRAINT ck_subscriptions_cancelled_pair CHECK ((((status)::text <> 'cancelled'::text) OR (cancelled_at IS NOT NULL))),
    CONSTRAINT ck_subscriptions_source CHECK (((source)::text = ANY ((ARRAY['purchase'::character varying, 'admin'::character varying])::text[]))),
    CONSTRAINT ck_subscriptions_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'past_due'::character varying, 'cancelled'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: TABLE subscriptions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.subscriptions IS 'Suscripciones del modelo freemium (RF-73). Da soporte a la validación de acceso a funciones de pago y a la métrica de conversión del plan de negocio. Conserva el historial de períodos para analítica de retención.';


--
-- Name: COLUMN subscriptions.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.subscriptions.status IS 'active | past_due | cancelled | expired. Solo una activa por usuario (índice parcial).';


--
-- Name: COLUMN subscriptions.provider_ref; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.subscriptions.provider_ref IS 'Referencia opaca a la pasarela de pago. NO se almacenan datos de tarjeta (cumplimiento PCI).';


--
-- Name: COLUMN subscriptions.plan_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.subscriptions.plan_id IS 'Plan contratado. Única referencia al catálogo de planes. Reemplazó a la columna de texto plan, que duplicaba plans.code y rompía 3FN.';


--
-- Name: COLUMN subscriptions.granted_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.subscriptions.granted_by IS 'Si la suscripcion la creo el personal a mano, quien fue. NULL = nacio de una compra del usuario.';


--
-- Name: COLUMN subscriptions.change_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.subscriptions.change_reason IS 'Motivo del cambio manual de plan (cortesia, correccion, compensacion...).';


--
-- Name: COLUMN subscriptions.source; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.subscriptions.source IS 'purchase = la compro el usuario (hay un cobro en billing_events). admin = la otorgo el personal a mano (cortesia o correccion). La conversion a premium se mide solo sobre purchase.';


--
-- Name: COLUMN subscriptions.cancel_requested_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.subscriptions.cancel_requested_at IS 'Cuando el usuario pidio no renovar. NULL = renueva. La suscripcion conserva el acceso hasta current_period_end.';


--
-- Name: support_articles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_articles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category character varying(24) NOT NULL,
    name character varying(120) NOT NULL,
    description character varying(1000) NOT NULL,
    reference_price numeric(12,2),
    currency character(3) DEFAULT 'CLP'::bpchar NOT NULL,
    external_url text,
    image_url text,
    is_featured boolean DEFAULT false NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_support_articles_category CHECK (((category)::text = ANY ((ARRAY['mobility'::character varying, 'bathroom'::character varying, 'bedroom'::character varying, 'hearing'::character varying, 'vision'::character varying, 'medication'::character varying, 'daily_living'::character varying, 'safety'::character varying, 'cognition'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT ck_support_articles_currency CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT ck_support_articles_description CHECK ((btrim((description)::text) <> ''::text)),
    CONSTRAINT ck_support_articles_external_url CHECK (((external_url IS NULL) OR (external_url ~ '^https://'::text))),
    CONSTRAINT ck_support_articles_image_url CHECK (((image_url IS NULL) OR (image_url ~ '^https://'::text))),
    CONSTRAINT ck_support_articles_name CHECK ((btrim((name)::text) <> ''::text)),
    CONSTRAINT ck_support_articles_price CHECK (((reference_price IS NULL) OR (reference_price >= (0)::numeric)))
);


--
-- Name: TABLE support_articles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.support_articles IS 'Catálogo compartido de artículos de apoyo al cuidado, agrupados por categoría. No pertenece a ningún paciente ni perfil, y no gestiona stock ni ventas: informa qué existe y dónde conseguirlo. RF-79.';


--
-- Name: COLUMN support_articles.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.id IS 'Identificador del artículo.';


--
-- Name: COLUMN support_articles.category; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.category IS 'Categoría del artículo. Lista cerrada, porque RF-79 filtra por ella.';


--
-- Name: COLUMN support_articles.name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.name IS 'Nombre del artículo.';


--
-- Name: COLUMN support_articles.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.description IS 'Para qué sirve y en qué casos se recomienda.';


--
-- Name: COLUMN support_articles.reference_price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.reference_price IS 'Precio de referencia orientativo. No es un precio de venta de AgeCare.';


--
-- Name: COLUMN support_articles.currency; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.currency IS 'Moneda del precio de referencia, en código ISO de tres letras.';


--
-- Name: COLUMN support_articles.external_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.external_url IS 'Enlace externo donde conseguirlo. Solo https.';


--
-- Name: COLUMN support_articles.image_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.image_url IS 'Imagen del artículo. Va como URL y no como file_id porque files exige un paciente.';


--
-- Name: COLUMN support_articles.is_featured; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.is_featured IS 'Si aparece destacado en la portada del catálogo.';


--
-- Name: COLUMN support_articles.display_order; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.display_order IS 'Orden de aparición dentro de su categoría.';


--
-- Name: COLUMN support_articles.created_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.created_by IS 'Quién lo cargó al catálogo.';


--
-- Name: COLUMN support_articles.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.created_at IS 'Fecha de creación del registro.';


--
-- Name: COLUMN support_articles.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.updated_at IS 'Fecha de la última modificación del registro.';


--
-- Name: COLUMN support_articles.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.support_articles.deleted_at IS 'Baja lógica. El artículo se conserva aunque deje de ofrecerse.';


--
-- Name: system_parameters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_parameters (
    key character varying(60) NOT NULL,
    value character varying(120) NOT NULL,
    value_type character varying(20) DEFAULT 'int'::character varying NOT NULL,
    description character varying(300) NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_system_parameters_type CHECK (((value_type)::text = ANY ((ARRAY['int'::character varying, 'minutes'::character varying, 'hours'::character varying, 'decimal'::character varying, 'bool'::character varying, 'text'::character varying])::text[])))
);


--
-- Name: TABLE system_parameters; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.system_parameters IS 'Catálogo clave-valor de parámetros de negocio configurables (umbrales de alertas, vigencias de tokens, ventanas de tiempo). Centraliza valores que antes vivían en el código; configurables y auditables sin redespliegue.';


--
-- Name: COLUMN system_parameters.value_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.system_parameters.value_type IS 'Interpretación del valor: int | minutes | hours | decimal | bool | text.';


--
-- Name: COLUMN system_parameters.updated_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.system_parameters.updated_by IS 'Último administrador que modificó el parámetro. Trazabilidad del cambio de configuración.';


--
-- Name: treatment_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.treatment_documents (
    treatment_id uuid NOT NULL,
    document_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE treatment_documents; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.treatment_documents IS 'Relaciona un tratamiento con la receta formal (medical_documents, category=prescription). La indicación es la orden ejecutable; la receta es el documento de respaldo. Son cosas distintas (DEF-014).';


--
-- Name: treatment_item_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.treatment_item_days (
    treatment_item_id uuid NOT NULL,
    day_of_week smallint NOT NULL,
    CONSTRAINT ck_treatment_item_days_range CHECK (((day_of_week >= 1) AND (day_of_week <= 7)))
);


--
-- Name: TABLE treatment_item_days; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.treatment_item_days IS 'Días habilitados de cada indicación (1FN). 1=lunes … 7=domingo.';


--
-- Name: treatment_item_prn_uses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.treatment_item_prn_uses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    treatment_item_id uuid NOT NULL,
    administered_at timestamp with time zone NOT NULL,
    reason character varying(200) NOT NULL,
    overrode_interval boolean DEFAULT false NOT NULL,
    logged_by uuid NOT NULL,
    logged_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_prn_uses_order CHECK ((administered_at <= (logged_at + '00:05:00'::interval))),
    CONSTRAINT ck_prn_uses_reason CHECK ((char_length(btrim((reason)::text)) >= 3))
);


--
-- Name: TABLE treatment_item_prn_uses; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.treatment_item_prn_uses IS 'Cada uso de una indicación SOS (is_prn): hora real, motivo y quién lo registró. Append-only. Sin patient_id (2FN): se llega por treatment_items → treatments.';


--
-- Name: COLUMN treatment_item_prn_uses.administered_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_item_prn_uses.administered_at IS 'Momento real en que se dio la dosis SOS. Distinto de logged_at (cuándo se anotó).';


--
-- Name: COLUMN treatment_item_prn_uses.reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_item_prn_uses.reason IS 'Por qué se dio (ej. "crisis de disnea"). Obligatorio: es lo que el médico necesita para ajustar el tratamiento.';


--
-- Name: COLUMN treatment_item_prn_uses.overrode_interval; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_item_prn_uses.overrode_interval IS 'true si se dio antes del intervalo mínimo de la indicación, tras confirmarlo.';


--
-- Name: treatment_item_times; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.treatment_item_times (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    treatment_item_id uuid NOT NULL,
    time_of_day time without time zone NOT NULL
);


--
-- Name: TABLE treatment_item_times; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.treatment_item_times IS 'Horarios de toma de cada indicación (1FN). HH:MM en la zona del paciente.';


--
-- Name: treatment_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.treatment_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    treatment_id uuid NOT NULL,
    name character varying(120) NOT NULL,
    dose_amount numeric(8,2) NOT NULL,
    dose_unit character varying(20) NOT NULL,
    dose_text character varying(60) GENERATED ALWAYS AS ((((trim_scale(dose_amount))::text || ' '::text) || (dose_unit)::text)) STORED,
    instructions text,
    grace_window_min smallint DEFAULT 60 NOT NULL,
    continues_item_id uuid,
    action character varying(10) DEFAULT 'kept'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    is_prn boolean DEFAULT false NOT NULL,
    schedule_label character varying(40),
    drug_code character varying(40),
    prn_min_interval_min smallint,
    CONSTRAINT ck_treatment_items_action CHECK (((action)::text = ANY ((ARRAY['added'::character varying, 'kept'::character varying, 'changed'::character varying, 'removed'::character varying])::text[]))),
    CONSTRAINT ck_treatment_items_dose_amount CHECK ((dose_amount > (0)::numeric)),
    CONSTRAINT ck_treatment_items_dose_unit CHECK (((dose_unit)::text = ANY ((ARRAY['mg'::character varying, 'g'::character varying, 'ml'::character varying, 'mcg'::character varying, 'UI'::character varying, 'gotas'::character varying, 'comprimido'::character varying, 'cápsula'::character varying, 'puff'::character varying, 'parche'::character varying])::text[]))),
    CONSTRAINT ck_treatment_items_grace CHECK (((grace_window_min >= 5) AND (grace_window_min <= 720))),
    CONSTRAINT ck_treatment_items_name_min CHECK ((char_length((name)::text) >= 2)),
    CONSTRAINT ck_treatment_items_prn_interval CHECK (((prn_min_interval_min IS NULL) OR (is_prn AND ((prn_min_interval_min >= 15) AND (prn_min_interval_min <= 1440)))))
);


--
-- Name: TABLE treatment_items; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.treatment_items IS 'Indicación farmacológica dentro de un tratamiento: fármaco + dosis + frecuencia. Las dosis concretas (scheduled_doses) cuelgan de aquí. Reemplaza, con versionado, a la fila suelta de medications.';


--
-- Name: COLUMN treatment_items.continues_item_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_items.continues_item_id IS 'Versión anterior del mismo fármaco. NULL si es nuevo (action=added).';


--
-- Name: COLUMN treatment_items.action; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_items.action IS 'added | kept | changed | removed. Respecto del tratamiento anterior. removed = el fármaco salió del esquema.';


--
-- Name: COLUMN treatment_items.is_prn; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_items.is_prn IS 'true = indicación condicional / SOS (pro re nata): NO genera dosis en la agenda; se registra al usarse. false = programada (genera agenda por horarios).';


--
-- Name: COLUMN treatment_items.schedule_label; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_items.schedule_label IS 'Etiqueta de referencia del momento de toma ("con el desayuno", "en ayunas"). Opcional. Es ayuda para el paciente; la frecuencia real son los horarios (medication/treatment_item_times).';


--
-- Name: COLUMN treatment_items.drug_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_items.drug_code IS 'Fármaco del catálogo del que viene la indicación (FK a drug_catalog). NULL si se indicó como texto libre. Permite aplicar el máximo de 24 h a los SOS.';


--
-- Name: COLUMN treatment_items.prn_min_interval_min; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatment_items.prn_min_interval_min IS 'Solo SOS: intervalo mínimo entre usos, en minutos (360 = cada 6 h). Un uso antes de tiempo se advierte y queda marcado.';


--
-- Name: treatments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.treatments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    status character varying(12) DEFAULT 'vigente'::character varying NOT NULL,
    prescribed_by uuid NOT NULL,
    prescriber_role character varying(10) DEFAULT 'doctor'::character varying NOT NULL,
    effective_from timestamp with time zone DEFAULT now() NOT NULL,
    effective_to timestamp with time zone,
    supersedes_id uuid,
    note character varying(500),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    specialty character varying(40) DEFAULT 'general'::character varying NOT NULL,
    review_date date,
    CONSTRAINT ck_treatments_cerrado_fechado CHECK ((((status)::text = 'vigente'::text) OR (effective_to IS NOT NULL))),
    CONSTRAINT ck_treatments_rango CHECK (((effective_to IS NULL) OR (effective_to >= effective_from))),
    CONSTRAINT ck_treatments_role CHECK (((prescriber_role)::text = ANY ((ARRAY['doctor'::character varying, 'caregiver'::character varying, 'family'::character varying])::text[]))),
    CONSTRAINT ck_treatments_status CHECK (((status)::text = ANY ((ARRAY['vigente'::character varying, 'superseded'::character varying, 'cancelled'::character varying])::text[]))),
    CONSTRAINT ck_treatments_vigente_abierto CHECK ((((status)::text <> 'vigente'::text) OR (effective_to IS NULL)))
);


--
-- Name: TABLE treatments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.treatments IS 'Esquema farmacológico de un paciente definido por el médico. Un solo vigente por paciente; los demás quedan como histórico (status=superseded) enlazados por supersedes_id. Cambiar el esquema crea uno nuevo, no edita en el lugar (DEF-007/008).';


--
-- Name: COLUMN treatments.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.status IS 'vigente | superseded | cancelled. Solo uno vigente por paciente.';


--
-- Name: COLUMN treatments.prescribed_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.prescribed_by IS 'Médico que definió el tratamiento. Siempre registrado (DEF-006).';


--
-- Name: COLUMN treatments.prescriber_role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.prescriber_role IS 'Rol de quien definio el tratamiento: doctor | caregiver | family. family solo en los tratamientos de arranque migrados del plan de medicamentos viejo, cuando no habia un medico que lo prescribiera (960).';


--
-- Name: COLUMN treatments.effective_from; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.effective_from IS 'Desde cuándo rige. Puede fecharse en el pasado (indicado ayer, registrado hoy).';


--
-- Name: COLUMN treatments.effective_to; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.effective_to IS 'Cuándo dejó de regir. NULL mientras está vigente.';


--
-- Name: COLUMN treatments.supersedes_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.supersedes_id IS 'Tratamiento anterior que este reemplazó. Arma la línea de tiempo.';


--
-- Name: COLUMN treatments.specialty; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.specialty IS 'Especialidad que define el tratamiento (general, cardiologia, traumatologia, ...). Permite varios tratamientos vigentes en paralelo, uno por especialidad, cada uno con su propio historial.';


--
-- Name: COLUMN treatments.review_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.treatments.review_date IS 'Fecha prevista de término o revisión del tratamiento. NULL = permanente/crónico. No es effective_to (eso es el reemplazo por versión).';


--
-- Name: usage_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_counters (
    subscription_id uuid NOT NULL,
    limit_key character varying(40) NOT NULL,
    period_start date NOT NULL,
    used_value integer DEFAULT 0 NOT NULL,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_usage_counters_key CHECK (((limit_key)::text ~ '^[a-z][a-z0-9_]{2,39}$'::text)),
    CONSTRAINT ck_usage_counters_periodo CHECK ((period_start = (date_trunc('month'::text, (period_start)::timestamp with time zone))::date)),
    CONSTRAINT ck_usage_counters_value CHECK ((used_value >= 0))
);


--
-- Name: TABLE usage_counters; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.usage_counters IS 'Consumo acumulado por suscripcion, limite y periodo mensual. Comparado contra plan_limits es lo que permite bloquear funciones premium. RF-73.';


--
-- Name: COLUMN usage_counters.subscription_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usage_counters.subscription_id IS 'Suscripcion que consume.';


--
-- Name: COLUMN usage_counters.limit_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usage_counters.limit_key IS 'Limite que se esta midiendo. Mismo nombre que en plan_limits.';


--
-- Name: COLUMN usage_counters.period_start; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usage_counters.period_start IS 'Primer dia del mes al que corresponde el contador.';


--
-- Name: COLUMN usage_counters.used_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usage_counters.used_value IS 'Cantidad consumida en el periodo.';


--
-- Name: COLUMN usage_counters.last_used_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usage_counters.last_used_at IS 'Ultima vez que el contador aumento.';


--
-- Name: COLUMN usage_counters.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usage_counters.created_at IS 'Fecha de creacion del registro.';


--
-- Name: COLUMN usage_counters.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usage_counters.updated_at IS 'Fecha de la ultima actualizacion del contador.';


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(254) NOT NULL,
    password_hash character varying(255) NOT NULL,
    first_name character varying(60) NOT NULL,
    last_name character varying(60) NOT NULL,
    phone character varying(16),
    avatar_url text,
    locale character varying(5) DEFAULT 'es'::character varying NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    is_staff boolean DEFAULT false NOT NULL,
    account_type character varying(10) DEFAULT 'family'::character varying NOT NULL,
    deactivated_at timestamp with time zone,
    deactivated_reason character varying(200),
    deactivated_by uuid,
    second_name character varying(60),
    second_last_name character varying(60),
    full_name character varying(250) GENERATED ALWAYS AS ((((((first_name)::text || COALESCE((' '::text || (second_name)::text), ''::text)) || ' '::text) || (last_name)::text) || COALESCE((' '::text || (second_last_name)::text), ''::text))) STORED,
    rut_number integer,
    rut_dv character(1),
    CONSTRAINT ck_users_account_type CHECK (((account_type)::text = ANY ((ARRAY['family'::character varying, 'caregiver'::character varying, 'doctor'::character varying, 'elder'::character varying])::text[]))),
    CONSTRAINT ck_users_first_name_min CHECK ((char_length((first_name)::text) >= 1)),
    CONSTRAINT ck_users_last_name_min CHECK ((char_length((last_name)::text) >= 1)),
    CONSTRAINT ck_users_locale CHECK (((locale)::text = ANY ((ARRAY['es'::character varying, 'en'::character varying])::text[]))),
    CONSTRAINT ck_users_rut_completo CHECK (((rut_number IS NULL) = (rut_dv IS NULL))),
    CONSTRAINT ck_users_rut_dv_correcto CHECK (((rut_number IS NULL) OR (rut_dv = public.rut_digito_verificador(rut_number)))),
    CONSTRAINT ck_users_rut_number CHECK (((rut_number IS NULL) OR ((rut_number >= 1000000) AND (rut_number <= 99999999)))),
    CONSTRAINT ck_users_second_last_name CHECK (((second_last_name IS NULL) OR (char_length(btrim((second_last_name)::text)) >= 1))),
    CONSTRAINT ck_users_second_name CHECK (((second_name IS NULL) OR (char_length(btrim((second_name)::text)) >= 1)))
);


--
-- Name: TABLE users; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.users IS 'Cuentas de usuario. El rol NO vive acá: un usuario puede tener roles distintos sobre distintos pacientes, y eso se resuelve en patient_members.';


--
-- Name: COLUMN users.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.id IS 'Identificador interno. UUID generado por la base.';


--
-- Name: COLUMN users.email; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.email IS 'Correo de acceso. Unicidad garantizada por ux_users_email_lower, sin distinguir mayúsculas.';


--
-- Name: COLUMN users.password_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.password_hash IS 'Hash argon2 o bcrypt. Nunca la contraseña en claro. Largo holgado porque el algoritmo aún no está decidido.';


--
-- Name: COLUMN users.phone; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.phone IS 'Teléfono en formato E.164, opcional.';


--
-- Name: COLUMN users.avatar_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.avatar_url IS 'URL de la foto de perfil. Opcional.';


--
-- Name: COLUMN users.locale; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.locale IS 'Idioma preferido de la interfaz. es | en.';


--
-- Name: COLUMN users.is_active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.is_active IS 'false = cuenta desactivada por soporte. Ticket AGE-208.';


--
-- Name: COLUMN users.created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.created_at IS 'Fecha de creación del registro.';


--
-- Name: COLUMN users.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.updated_at IS 'Fecha de última modificación. La mantiene el trigger tg_users_updated_at.';


--
-- Name: COLUMN users.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.deleted_at IS 'Baja lógica para la eliminación de cuenta. Ticket AGE-1007, requisito de Google Play. NULL = vigente.';


--
-- Name: COLUMN users.is_staff; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.is_staff IS 'Personal de Alloxentric: puede administrar planes, funcionalidades, limites y precios. NO da acceso a ningun expediente; para eso sigue haciendo falta la membresia en patient_members.';


--
-- Name: COLUMN users.account_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.account_type IS 'Tipo de persona para la plataforma: family | caregiver | doctor | elder. Se elige al registrarse (solo family o caregiver); doctor exige habilitacion del personal (doctor_profiles); elder lo crea la familia. NO reemplaza patient_members.role, que es el rol de la relacion con cada paciente.';


--
-- Name: COLUMN users.deactivated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.deactivated_at IS 'Cuando el personal desactivo la cuenta. NULL = no esta desactivada. Distinto de deleted_at, que es la baja pedida por el propio usuario.';


--
-- Name: COLUMN users.deactivated_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.deactivated_reason IS 'Motivo de la desactivacion, escrito por el personal.';


--
-- Name: COLUMN users.deactivated_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.deactivated_by IS 'Miembro del personal que la desactivo.';


--
-- Name: COLUMN users.second_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.second_name IS 'Segundo nombre. Opcional: no toda persona lo tiene.';


--
-- Name: COLUMN users.second_last_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.second_last_name IS 'Segundo apellido (materno). Opcional: no toda persona lo tiene.';


--
-- Name: COLUMN users.full_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.full_name IS 'Columna generada: nombre, segundo nombre, apellido y segundo apellido, sin huecos. Solo lectura.';


--
-- Name: COLUMN users.rut_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.rut_number IS 'Número del RUT, sin dígito verificador. Opcional en la tabla; la API lo exige a la cuidadora. Único entre cuentas.';


--
-- Name: COLUMN users.rut_dv; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.rut_dv IS 'Dígito verificador del RUT. Derivado de rut_number por el módulo 11 y verificado con un CHECK.';


--
-- Name: vaccine_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vaccine_catalog (
    code character varying(30) NOT NULL,
    label character varying(100) NOT NULL,
    kind_default character varying(20) DEFAULT 'preventiva'::character varying NOT NULL,
    is_recurrent boolean DEFAULT false NOT NULL,
    interval_months integer,
    target_group character varying(80),
    CONSTRAINT ck_vaccine_catalog_code_min CHECK ((char_length((code)::text) >= 2)),
    CONSTRAINT ck_vaccine_catalog_interval CHECK (((interval_months IS NULL) OR (interval_months > 0))),
    CONSTRAINT ck_vaccine_catalog_kind CHECK (((kind_default)::text = ANY ((ARRAY['preventiva'::character varying, 'post_exposicion'::character varying])::text[])))
);


--
-- Name: TABLE vaccine_catalog; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.vaccine_catalog IS 'Catálogo de vacunas (fuente única de verdad, igual que vital_types). Las propiedades inherentes de cada vacuna (naturaleza, si es recurrente, intervalo recomendado, grupo objetivo) viven aquí, no se repiten por dosis (3FN). Fuente: Programa Nacional de Inmunizaciones (PNI) MINSAL.';


--
-- Name: COLUMN vaccine_catalog.kind_default; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vaccine_catalog.kind_default IS 'Naturaleza por defecto: preventiva (programa, con próxima dosis) | post_exposicion (evento gatillado, p. ej. antirrábica tras mordedura).';


--
-- Name: COLUMN vaccine_catalog.is_recurrent; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vaccine_catalog.is_recurrent IS 'true si se repite en el tiempo (influenza anual, refuerzos). Habilita el cálculo de next_due_on con interval_months.';


--
-- Name: COLUMN vaccine_catalog.interval_months; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vaccine_catalog.interval_months IS 'Intervalo recomendado entre dosis, en meses. NULL = dosis única o no aplica.';


--
-- Name: COLUMN vaccine_catalog.target_group; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vaccine_catalog.target_group IS 'Grupo objetivo según el PNI (texto informativo para mostrar, no para lógica).';


--
-- Name: vital_readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
)
PARTITION BY RANGE (measured_at);


--
-- Name: TABLE vital_readings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.vital_readings IS 'Mediciones de signos vitales. Particionada por mes (RNF-07). Tabla append-only. PK (id, measured_at): excepción técnica de PostgreSQL para tablas particionadas, documentada en el constraint pk_vital_readings.';


--
-- Name: COLUMN vital_readings.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_readings.type IS 'Tipo de signo vital. FK a vital_types.code (catálogo centralizado). Reemplaza el CHECK de lista duplicada.';


--
-- Name: COLUMN vital_readings.value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_readings.value IS 'Valor principal. En presión arterial: sistólica.';


--
-- Name: COLUMN vital_readings.value_secondary; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_readings.value_secondary IS 'Solo para blood_pressure: diastólica. NULL en todos los demás tipos.';


--
-- Name: COLUMN vital_readings.measured_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_readings.measured_at IS 'Momento de la medición. Columna de particionamiento. Parte de la PK por requerimiento técnico de PostgreSQL, no por diseño relacional.';


--
-- Name: COLUMN vital_readings.source; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_readings.source IS 'wearable = automática del dispositivo. manual = registrada por la cuidadora (RF-18).';


--
-- Name: COLUMN vital_readings.meta; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_readings.meta IS 'Datos adicionales del proveedor del wearable. jsonb INTENCIONAL: cada proveedor (Garmin, Whoop, HealthKit) envía campos distintos y opcionales. No se consulta ni se filtra: solo se conserva como trazabilidad. Excepción documentada a 1FN.';


--
-- Name: vital_readings_2025_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2025_11 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2025_12; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2025_12 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_01; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_01 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_02; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_02 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_03; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_03 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_04; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_04 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_05; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_05 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_06; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_06 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_07; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_07 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_08; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_08 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_09; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_09 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_10 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_11 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2026_12; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2026_12 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_01; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_01 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_02; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_02 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_03; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_03 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_04; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_04 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_05; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_05 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_06; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_06 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_07; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_07 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_08; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_08 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_09; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_09 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_10 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_2027_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_2027_11 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_readings_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_readings_default (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    value numeric(8,2) NOT NULL,
    value_secondary numeric(8,2),
    measured_at timestamp with time zone NOT NULL,
    source character varying(10) NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vital_readings_secondary CHECK (((value_secondary IS NULL) OR ((type)::text = 'blood_pressure'::text))),
    CONSTRAINT ck_vital_readings_secondary_sane CHECK (((value_secondary IS NULL) OR ((value_secondary >= (0)::numeric) AND (value_secondary <= (100000)::numeric)))),
    CONSTRAINT ck_vital_readings_source CHECK (((source)::text = ANY ((ARRAY['wearable'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT ck_vital_readings_value_sane CHECK (((value >= (0)::numeric) AND (value <= (100000)::numeric)))
);


--
-- Name: vital_thresholds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_thresholds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    type character varying(16) NOT NULL,
    min_value numeric(8,2),
    max_value numeric(8,2),
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_vital_thresholds_at_least_one CHECK (((min_value IS NOT NULL) OR (max_value IS NOT NULL))),
    CONSTRAINT ck_vital_thresholds_range CHECK (((min_value IS NULL) OR (max_value IS NULL) OR (min_value < max_value)))
);


--
-- Name: TABLE vital_thresholds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.vital_thresholds IS 'Rango normal de cada signo vital por paciente. Define cuándo una lectura dispara una alerta vital_out_of_range.';


--
-- Name: COLUMN vital_thresholds.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_thresholds.type IS 'Tipo de signo vital. FK a vital_types.code: reemplaza el CHECK de lista duplicada que existía en vital_readings y aquí.';


--
-- Name: COLUMN vital_thresholds.min_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_thresholds.min_value IS 'Límite inferior. NULL si el vital solo tiene techo (ej. temperatura).';


--
-- Name: COLUMN vital_thresholds.max_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_thresholds.max_value IS 'Límite superior. NULL si el vital solo tiene piso (ej. saturación O₂).';


--
-- Name: COLUMN vital_thresholds.updated_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_thresholds.updated_by IS 'Quién configuró el umbral por última vez (RF-21). ON DELETE RESTRICT: se conserva el registro de quién lo definió.';


--
-- Name: COLUMN vital_thresholds.deleted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_thresholds.deleted_at IS 'Baja lógica. Un umbral reemplazado se desactiva; se conserva el histórico de rangos para trazabilidad y analítica.';


--
-- Name: vital_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vital_types (
    code character varying(16) NOT NULL,
    label character varying(60) NOT NULL,
    unit character varying(10) DEFAULT ''::character varying NOT NULL,
    has_secondary boolean DEFAULT false NOT NULL,
    CONSTRAINT ck_vital_types_code_min CHECK ((char_length((code)::text) >= 2))
);


--
-- Name: TABLE vital_types; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.vital_types IS 'Catálogo de tipos de signos vitales. Fuente única de verdad: reemplaza los CHECK duplicados en vital_readings y vital_thresholds. Agregar un nuevo tipo aquí lo habilita automáticamente en todo el sistema.';


--
-- Name: COLUMN vital_types.code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_types.code IS 'Identificador corto usado en la API y en las tablas de mediciones.';


--
-- Name: COLUMN vital_types.unit; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_types.unit IS 'Unidad de presentación. Reemplaza el dict UNITS hardcodeado en vitals.py.';


--
-- Name: COLUMN vital_types.has_secondary; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.vital_types.has_secondary IS 'true solo para blood_pressure (sistólica + diastólica). Usado por el CHECK ck_vital_readings_secondary.';


--
-- Name: wearables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wearables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    provider character varying(20) DEFAULT 'simulator'::character varying NOT NULL,
    serial_number character varying(64) NOT NULL,
    model character varying(60),
    battery_pct smallint,
    last_sync_at timestamp with time zone,
    unlinked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_wearables_battery CHECK (((battery_pct IS NULL) OR ((battery_pct >= 0) AND (battery_pct <= 100)))),
    CONSTRAINT ck_wearables_provider CHECK (((provider)::text = ANY ((ARRAY['simulator'::character varying, 'healthkit'::character varying, 'health_connect'::character varying, 'garmin'::character varying, 'whoop'::character varying])::text[]))),
    CONSTRAINT ck_wearables_unlinked CHECK (((unlinked_at IS NULL) OR (unlinked_at >= created_at)))
);


--
-- Name: TABLE wearables; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.wearables IS 'Dispositivo vestible vinculado a un paciente. Guarda el aparato y su estado; las mediciones viven en vital_readings.';


--
-- Name: COLUMN wearables.provider; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.wearables.provider IS 'Origen de los datos: simulator (v1 del plan) | healthkit | health_connect | garmin | whoop, vía Spike API.';


--
-- Name: COLUMN wearables.serial_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.wearables.serial_number IS 'Número de serie del aparato. Único junto al proveedor, y solo entre los vinculados: un reloj desvinculado puede asignarse a otro paciente.';


--
-- Name: COLUMN wearables.battery_pct; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.wearables.battery_pct IS 'Nivel de batería, 0 a 100. NULL si el aparato aún no ha reportado (RF-16).';


--
-- Name: COLUMN wearables.last_sync_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.wearables.last_sync_at IS 'Última medición recibida. Base de la alerta wearable_offline: sin datos por más de 2 horas (Anexo B). NO se guarda un estado "conectado": se calcula comparando con la hora actual.';


--
-- Name: COLUMN wearables.unlinked_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.wearables.unlinked_at IS 'Desvinculación. NULL = vigente. Se conserva la fila para mantener el historial de aparatos del paciente.';


--
-- Name: wellbeing_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wellbeing_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    patient_id uuid NOT NULL,
    snapshot_date date NOT NULL,
    status character varying(12) NOT NULL,
    reasons jsonb DEFAULT '[]'::jsonb NOT NULL,
    vitals_out_of_range smallint DEFAULT 0 NOT NULL,
    doses_missed smallint DEFAULT 0 NOT NULL,
    active_alerts smallint DEFAULT 0 NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_wellbeing_snapshots_reasons_array CHECK ((jsonb_typeof(reasons) = 'array'::text)),
    CONSTRAINT ck_wellbeing_snapshots_status CHECK (((status)::text = ANY ((ARRAY['ok'::character varying, 'warning'::character varying, 'attention'::character varying])::text[])))
);


--
-- Name: TABLE wellbeing_snapshots; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.wellbeing_snapshots IS 'Fotografía diaria del semáforo de bienestar por paciente (ok | warning | attention). Historiza un indicador que de otro modo se perdería al calcularse al vuelo, dando soporte al expediente histórico y a la analítica de tendencias.';


--
-- Name: COLUMN wellbeing_snapshots.reasons; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.wellbeing_snapshots.reasons IS 'Motivos del estado del día, como texto ya redactado para mostrar. jsonb INTENCIONAL y excepción documentada a 1FN: no son códigos de un catálogo, nunca se consultan ni se cruzan, y las cifras que sí se analizan están normalizadas en vitals_out_of_range, doses_missed y active_alerts. Normalizarlo daría integridad sobre datos que solo se pintan en pantalla.';


--
-- Name: COLUMN wellbeing_snapshots.vitals_out_of_range; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.wellbeing_snapshots.vitals_out_of_range IS 'Conteo de vitales fuera de rango ese día; respalda y audita el cálculo del estado.';


--
-- Name: analytics_events_202610; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202610 FOR VALUES FROM ('2026-10-01 00:00:00-04') TO ('2026-11-01 00:00:00-04');


--
-- Name: analytics_events_202611; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202611 FOR VALUES FROM ('2026-11-01 00:00:00-04') TO ('2026-12-01 00:00:00-04');


--
-- Name: analytics_events_202612; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202612 FOR VALUES FROM ('2026-12-01 00:00:00-04') TO ('2027-01-01 00:00:00-04');


--
-- Name: analytics_events_202701; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202701 FOR VALUES FROM ('2027-01-01 00:00:00-04') TO ('2027-02-01 00:00:00-04');


--
-- Name: analytics_events_202702; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202702 FOR VALUES FROM ('2027-02-01 00:00:00-04') TO ('2027-03-01 00:00:00-04');


--
-- Name: analytics_events_202703; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202703 FOR VALUES FROM ('2027-03-01 00:00:00-04') TO ('2027-04-01 00:00:00-04');


--
-- Name: analytics_events_202704; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202704 FOR VALUES FROM ('2027-04-01 00:00:00-04') TO ('2027-05-01 00:00:00-04');


--
-- Name: analytics_events_202705; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202705 FOR VALUES FROM ('2027-05-01 00:00:00-04') TO ('2027-06-01 00:00:00-04');


--
-- Name: analytics_events_202706; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202706 FOR VALUES FROM ('2027-06-01 00:00:00-04') TO ('2027-07-01 00:00:00-04');


--
-- Name: analytics_events_202707; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202707 FOR VALUES FROM ('2027-07-01 00:00:00-04') TO ('2027-08-01 00:00:00-04');


--
-- Name: analytics_events_202708; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202708 FOR VALUES FROM ('2027-08-01 00:00:00-04') TO ('2027-09-01 00:00:00-04');


--
-- Name: analytics_events_202709; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202709 FOR VALUES FROM ('2027-09-01 00:00:00-04') TO ('2027-10-01 00:00:00-04');


--
-- Name: analytics_events_202710; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202710 FOR VALUES FROM ('2027-10-01 00:00:00-04') TO ('2027-11-01 00:00:00-04');


--
-- Name: analytics_events_202711; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202711 FOR VALUES FROM ('2027-11-01 00:00:00-04') TO ('2027-12-01 00:00:00-04');


--
-- Name: analytics_events_202712; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_202712 FOR VALUES FROM ('2027-12-01 00:00:00-04') TO ('2028-01-01 00:00:00-04');


--
-- Name: analytics_events_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ATTACH PARTITION public.analytics_events_default DEFAULT;


--
-- Name: record_access_log_202610; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202610 FOR VALUES FROM ('2026-10-01 00:00:00-04') TO ('2026-11-01 00:00:00-04');


--
-- Name: record_access_log_202611; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202611 FOR VALUES FROM ('2026-11-01 00:00:00-04') TO ('2026-12-01 00:00:00-04');


--
-- Name: record_access_log_202612; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202612 FOR VALUES FROM ('2026-12-01 00:00:00-04') TO ('2027-01-01 00:00:00-04');


--
-- Name: record_access_log_202701; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202701 FOR VALUES FROM ('2027-01-01 00:00:00-04') TO ('2027-02-01 00:00:00-04');


--
-- Name: record_access_log_202702; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202702 FOR VALUES FROM ('2027-02-01 00:00:00-04') TO ('2027-03-01 00:00:00-04');


--
-- Name: record_access_log_202703; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202703 FOR VALUES FROM ('2027-03-01 00:00:00-04') TO ('2027-04-01 00:00:00-04');


--
-- Name: record_access_log_202704; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202704 FOR VALUES FROM ('2027-04-01 00:00:00-04') TO ('2027-05-01 00:00:00-04');


--
-- Name: record_access_log_202705; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202705 FOR VALUES FROM ('2027-05-01 00:00:00-04') TO ('2027-06-01 00:00:00-04');


--
-- Name: record_access_log_202706; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202706 FOR VALUES FROM ('2027-06-01 00:00:00-04') TO ('2027-07-01 00:00:00-04');


--
-- Name: record_access_log_202707; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202707 FOR VALUES FROM ('2027-07-01 00:00:00-04') TO ('2027-08-01 00:00:00-04');


--
-- Name: record_access_log_202708; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202708 FOR VALUES FROM ('2027-08-01 00:00:00-04') TO ('2027-09-01 00:00:00-04');


--
-- Name: record_access_log_202709; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202709 FOR VALUES FROM ('2027-09-01 00:00:00-04') TO ('2027-10-01 00:00:00-04');


--
-- Name: record_access_log_202710; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202710 FOR VALUES FROM ('2027-10-01 00:00:00-04') TO ('2027-11-01 00:00:00-04');


--
-- Name: record_access_log_202711; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202711 FOR VALUES FROM ('2027-11-01 00:00:00-04') TO ('2027-12-01 00:00:00-04');


--
-- Name: record_access_log_202712; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_202712 FOR VALUES FROM ('2027-12-01 00:00:00-04') TO ('2028-01-01 00:00:00-04');


--
-- Name: record_access_log_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log ATTACH PARTITION public.record_access_log_default DEFAULT;


--
-- Name: vital_readings_2025_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2025_11 FOR VALUES FROM ('2025-10-31 20:00:00-04') TO ('2025-11-30 20:00:00-04');


--
-- Name: vital_readings_2025_12; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2025_12 FOR VALUES FROM ('2025-11-30 20:00:00-04') TO ('2025-12-31 20:00:00-04');


--
-- Name: vital_readings_2026_01; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_01 FOR VALUES FROM ('2025-12-31 20:00:00-04') TO ('2026-01-31 20:00:00-04');


--
-- Name: vital_readings_2026_02; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_02 FOR VALUES FROM ('2026-01-31 20:00:00-04') TO ('2026-02-28 20:00:00-04');


--
-- Name: vital_readings_2026_03; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_03 FOR VALUES FROM ('2026-02-28 20:00:00-04') TO ('2026-03-31 20:00:00-04');


--
-- Name: vital_readings_2026_04; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_04 FOR VALUES FROM ('2026-03-31 20:00:00-04') TO ('2026-04-30 20:00:00-04');


--
-- Name: vital_readings_2026_05; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_05 FOR VALUES FROM ('2026-04-30 20:00:00-04') TO ('2026-05-31 20:00:00-04');


--
-- Name: vital_readings_2026_06; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_06 FOR VALUES FROM ('2026-05-31 20:00:00-04') TO ('2026-06-30 20:00:00-04');


--
-- Name: vital_readings_2026_07; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_07 FOR VALUES FROM ('2026-06-30 20:00:00-04') TO ('2026-07-31 20:00:00-04');


--
-- Name: vital_readings_2026_08; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_08 FOR VALUES FROM ('2026-07-31 20:00:00-04') TO ('2026-08-31 20:00:00-04');


--
-- Name: vital_readings_2026_09; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_09 FOR VALUES FROM ('2026-08-31 20:00:00-04') TO ('2026-09-30 20:00:00-04');


--
-- Name: vital_readings_2026_10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_10 FOR VALUES FROM ('2026-09-30 20:00:00-04') TO ('2026-10-31 20:00:00-04');


--
-- Name: vital_readings_2026_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_11 FOR VALUES FROM ('2026-10-31 20:00:00-04') TO ('2026-11-30 20:00:00-04');


--
-- Name: vital_readings_2026_12; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2026_12 FOR VALUES FROM ('2026-11-30 20:00:00-04') TO ('2026-12-31 20:00:00-04');


--
-- Name: vital_readings_2027_01; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_01 FOR VALUES FROM ('2026-12-31 20:00:00-04') TO ('2027-01-31 20:00:00-04');


--
-- Name: vital_readings_2027_02; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_02 FOR VALUES FROM ('2027-01-31 20:00:00-04') TO ('2027-02-28 20:00:00-04');


--
-- Name: vital_readings_2027_03; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_03 FOR VALUES FROM ('2027-02-28 20:00:00-04') TO ('2027-03-31 20:00:00-04');


--
-- Name: vital_readings_2027_04; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_04 FOR VALUES FROM ('2027-03-31 20:00:00-04') TO ('2027-04-30 20:00:00-04');


--
-- Name: vital_readings_2027_05; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_05 FOR VALUES FROM ('2027-04-30 20:00:00-04') TO ('2027-05-31 20:00:00-04');


--
-- Name: vital_readings_2027_06; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_06 FOR VALUES FROM ('2027-05-31 20:00:00-04') TO ('2027-06-30 20:00:00-04');


--
-- Name: vital_readings_2027_07; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_07 FOR VALUES FROM ('2027-06-30 20:00:00-04') TO ('2027-07-31 20:00:00-04');


--
-- Name: vital_readings_2027_08; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_08 FOR VALUES FROM ('2027-07-31 20:00:00-04') TO ('2027-08-31 20:00:00-04');


--
-- Name: vital_readings_2027_09; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_09 FOR VALUES FROM ('2027-08-31 20:00:00-04') TO ('2027-09-30 20:00:00-04');


--
-- Name: vital_readings_2027_10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_10 FOR VALUES FROM ('2027-09-30 20:00:00-04') TO ('2027-10-31 20:00:00-04');


--
-- Name: vital_readings_2027_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_2027_11 FOR VALUES FROM ('2027-10-31 20:00:00-04') TO ('2027-11-30 20:00:00-04');


--
-- Name: vital_readings_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings ATTACH PARTITION public.vital_readings_default DEFAULT;


--
-- Name: activity_reports activity_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_reports
    ADD CONSTRAINT activity_reports_pkey PRIMARY KEY (id);


--
-- Name: activity_sessions activity_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_sessions
    ADD CONSTRAINT activity_sessions_pkey PRIMARY KEY (id);


--
-- Name: admin_audit_log admin_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_audit_log
    ADD CONSTRAINT admin_audit_log_pkey PRIMARY KEY (id);


--
-- Name: alert_deliveries alert_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_deliveries
    ADD CONSTRAINT alert_deliveries_pkey PRIMARY KEY (id);


--
-- Name: alerts alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT alerts_pkey PRIMARY KEY (id);


--
-- Name: allergen_catalog allergen_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allergen_catalog
    ADD CONSTRAINT allergen_catalog_pkey PRIMARY KEY (code);


--
-- Name: analytics_events analytics_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events
    ADD CONSTRAINT analytics_events_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202610 analytics_events_202610_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202610
    ADD CONSTRAINT analytics_events_202610_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202611 analytics_events_202611_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202611
    ADD CONSTRAINT analytics_events_202611_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202612 analytics_events_202612_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202612
    ADD CONSTRAINT analytics_events_202612_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202701 analytics_events_202701_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202701
    ADD CONSTRAINT analytics_events_202701_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202702 analytics_events_202702_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202702
    ADD CONSTRAINT analytics_events_202702_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202703 analytics_events_202703_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202703
    ADD CONSTRAINT analytics_events_202703_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202704 analytics_events_202704_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202704
    ADD CONSTRAINT analytics_events_202704_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202705 analytics_events_202705_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202705
    ADD CONSTRAINT analytics_events_202705_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202706 analytics_events_202706_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202706
    ADD CONSTRAINT analytics_events_202706_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202707 analytics_events_202707_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202707
    ADD CONSTRAINT analytics_events_202707_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202708 analytics_events_202708_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202708
    ADD CONSTRAINT analytics_events_202708_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202709 analytics_events_202709_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202709
    ADD CONSTRAINT analytics_events_202709_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202710 analytics_events_202710_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202710
    ADD CONSTRAINT analytics_events_202710_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202711 analytics_events_202711_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202711
    ADD CONSTRAINT analytics_events_202711_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_202712 analytics_events_202712_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_202712
    ADD CONSTRAINT analytics_events_202712_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: analytics_events_default analytics_events_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events_default
    ADD CONSTRAINT analytics_events_default_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: assistant_citations assistant_citations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_citations
    ADD CONSTRAINT assistant_citations_pkey PRIMARY KEY (id);


--
-- Name: assistant_queries assistant_queries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_queries
    ADD CONSTRAINT assistant_queries_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: billing_events billing_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT billing_events_pkey PRIMARY KEY (id);


--
-- Name: care_observations care_observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_observations
    ADD CONSTRAINT care_observations_pkey PRIMARY KEY (id);


--
-- Name: care_shifts care_shifts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_shifts
    ADD CONSTRAINT care_shifts_pkey PRIMARY KEY (id);


--
-- Name: care_tasks care_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_tasks
    ADD CONSTRAINT care_tasks_pkey PRIMARY KEY (id);


--
-- Name: caregiver_certifications caregiver_certifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_certifications
    ADD CONSTRAINT caregiver_certifications_pkey PRIMARY KEY (id);


--
-- Name: caregiver_languages caregiver_languages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_languages
    ADD CONSTRAINT caregiver_languages_pkey PRIMARY KEY (profile_id, language_code);


--
-- Name: caregiver_profiles caregiver_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_profiles
    ADD CONSTRAINT caregiver_profiles_pkey PRIMARY KEY (id);


--
-- Name: caregiver_reviews caregiver_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_reviews
    ADD CONSTRAINT caregiver_reviews_pkey PRIMARY KEY (id);


--
-- Name: caregiver_specialties caregiver_specialties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_specialties
    ADD CONSTRAINT caregiver_specialties_pkey PRIMARY KEY (profile_id, specialty_code);


--
-- Name: caregiver_zones caregiver_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_zones
    ADD CONSTRAINT caregiver_zones_pkey PRIMARY KEY (profile_id, commune_code);


--
-- Name: chat_ws_sessions chat_ws_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_ws_sessions
    ADD CONSTRAINT chat_ws_sessions_pkey PRIMARY KEY (id);


--
-- Name: elder_devices ck_elder_devices_cuenta; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.elder_devices
    ADD CONSTRAINT ck_elder_devices_cuenta CHECK (((unlinked_at IS NOT NULL) OR (user_id IS NOT NULL))) NOT VALID;


--
-- Name: subscriptions ck_subscriptions_plan_id; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.subscriptions
    ADD CONSTRAINT ck_subscriptions_plan_id CHECK ((plan_id IS NOT NULL)) NOT VALID;


--
-- Name: condition_catalog condition_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.condition_catalog
    ADD CONSTRAINT condition_catalog_pkey PRIMARY KEY (code);


--
-- Name: contact_requests contact_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_requests
    ADD CONSTRAINT contact_requests_pkey PRIMARY KEY (id);


--
-- Name: content_items content_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_items
    ADD CONSTRAINT content_items_pkey PRIMARY KEY (id);


--
-- Name: content_playbacks content_playbacks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_playbacks
    ADD CONSTRAINT content_playbacks_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: creation_shares creation_shares_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creation_shares
    ADD CONSTRAINT creation_shares_pkey PRIMARY KEY (id);


--
-- Name: daily_checkins daily_checkins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_checkins
    ADD CONSTRAINT daily_checkins_pkey PRIMARY KEY (id);


--
-- Name: device_link_codes device_link_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_link_codes
    ADD CONSTRAINT device_link_codes_pkey PRIMARY KEY (id);


--
-- Name: doctor_enrollments doctor_enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doctor_enrollments
    ADD CONSTRAINT doctor_enrollments_pkey PRIMARY KEY (id);


--
-- Name: doctor_profiles doctor_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doctor_profiles
    ADD CONSTRAINT doctor_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: drug_catalog drug_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drug_catalog
    ADD CONSTRAINT drug_catalog_pkey PRIMARY KEY (code);


--
-- Name: elder_devices elder_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT elder_devices_pkey PRIMARY KEY (id);


--
-- Name: elder_feed_items elder_feed_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_feed_items
    ADD CONSTRAINT elder_feed_items_pkey PRIMARY KEY (id);


--
-- Name: emergency_contacts emergency_contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emergency_contacts
    ADD CONSTRAINT emergency_contacts_pkey PRIMARY KEY (id);


--
-- Name: plan_prices ex_plan_prices_sin_solape; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_prices
    ADD CONSTRAINT ex_plan_prices_sin_solape EXCLUDE USING gist (plan_id WITH =, currency WITH =, period WITH =, tstzrange(valid_from, valid_to) WITH &&);


--
-- Name: features features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.features
    ADD CONSTRAINT features_pkey PRIMARY KEY (code);


--
-- Name: file_ocr file_ocr_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_ocr
    ADD CONSTRAINT file_ocr_pkey PRIMARY KEY (file_id);


--
-- Name: files files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_pkey PRIMARY KEY (id);


--
-- Name: form_route_unit_rules form_route_unit_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_route_unit_rules
    ADD CONSTRAINT form_route_unit_rules_pkey PRIMARY KEY (form, route, unit);


--
-- Name: gallery_photos gallery_photos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gallery_photos
    ADD CONSTRAINT gallery_photos_pkey PRIMARY KEY (id);


--
-- Name: idempotency_keys idempotency_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (id);


--
-- Name: incidents incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_pkey PRIMARY KEY (id);


--
-- Name: invitations invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_pkey PRIMARY KEY (id);


--
-- Name: job_offers job_offers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_offers
    ADD CONSTRAINT job_offers_pkey PRIMARY KEY (id);


--
-- Name: limit_keys limit_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.limit_keys
    ADD CONSTRAINT limit_keys_pkey PRIMARY KEY (key);


--
-- Name: market_products market_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.market_products
    ADD CONSTRAINT market_products_pkey PRIMARY KEY (id);


--
-- Name: medical_documents medical_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_documents
    ADD CONSTRAINT medical_documents_pkey PRIMARY KEY (id);


--
-- Name: medication_days medication_days_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medication_days
    ADD CONSTRAINT medication_days_pkey PRIMARY KEY (medication_id, day_of_week);


--
-- Name: medication_times medication_times_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medication_times
    ADD CONSTRAINT medication_times_pkey PRIMARY KEY (id);


--
-- Name: medications medications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medications
    ADD CONSTRAINT medications_pkey PRIMARY KEY (id);


--
-- Name: message_receipts message_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_receipts
    ADD CONSTRAINT message_receipts_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: music_creations music_creations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.music_creations
    ADD CONSTRAINT music_creations_pkey PRIMARY KEY (id);


--
-- Name: notification_settings notification_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT notification_settings_pkey PRIMARY KEY (id);


--
-- Name: password_reset_tokens password_reset_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_pkey PRIMARY KEY (id);


--
-- Name: patient_allergies patient_allergies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_allergies
    ADD CONSTRAINT patient_allergies_pkey PRIMARY KEY (id);


--
-- Name: patient_conditions patient_conditions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_conditions
    ADD CONSTRAINT patient_conditions_pkey PRIMARY KEY (id);


--
-- Name: patient_immunizations patient_immunizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_immunizations
    ADD CONSTRAINT patient_immunizations_pkey PRIMARY KEY (id);


--
-- Name: patient_measurements patient_measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_measurements
    ADD CONSTRAINT patient_measurements_pkey PRIMARY KEY (id);


--
-- Name: patient_members patient_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_members
    ADD CONSTRAINT patient_members_pkey PRIMARY KEY (id);


--
-- Name: patients patients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patients
    ADD CONSTRAINT patients_pkey PRIMARY KEY (id);


--
-- Name: photo_reactions photo_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.photo_reactions
    ADD CONSTRAINT photo_reactions_pkey PRIMARY KEY (id);


--
-- Name: vital_readings pk_vital_readings; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings
    ADD CONSTRAINT pk_vital_readings PRIMARY KEY (id, measured_at);


--
-- Name: plan_features plan_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_features
    ADD CONSTRAINT plan_features_pkey PRIMARY KEY (plan_id, feature_code);


--
-- Name: plan_limits plan_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_limits
    ADD CONSTRAINT plan_limits_pkey PRIMARY KEY (plan_id, limit_key);


--
-- Name: plan_prices plan_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_prices
    ADD CONSTRAINT plan_prices_pkey PRIMARY KEY (id);


--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT plans_pkey PRIMARY KEY (id);


--
-- Name: push_devices push_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_devices
    ADD CONSTRAINT push_devices_pkey PRIMARY KEY (id);


--
-- Name: record_access_log record_access_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log
    ADD CONSTRAINT record_access_log_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202610 record_access_log_202610_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202610
    ADD CONSTRAINT record_access_log_202610_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202611 record_access_log_202611_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202611
    ADD CONSTRAINT record_access_log_202611_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202612 record_access_log_202612_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202612
    ADD CONSTRAINT record_access_log_202612_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202701 record_access_log_202701_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202701
    ADD CONSTRAINT record_access_log_202701_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202702 record_access_log_202702_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202702
    ADD CONSTRAINT record_access_log_202702_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202703 record_access_log_202703_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202703
    ADD CONSTRAINT record_access_log_202703_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202704 record_access_log_202704_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202704
    ADD CONSTRAINT record_access_log_202704_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202705 record_access_log_202705_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202705
    ADD CONSTRAINT record_access_log_202705_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202706 record_access_log_202706_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202706
    ADD CONSTRAINT record_access_log_202706_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202707 record_access_log_202707_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202707
    ADD CONSTRAINT record_access_log_202707_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202708 record_access_log_202708_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202708
    ADD CONSTRAINT record_access_log_202708_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202709 record_access_log_202709_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202709
    ADD CONSTRAINT record_access_log_202709_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202710 record_access_log_202710_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202710
    ADD CONSTRAINT record_access_log_202710_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202711 record_access_log_202711_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202711
    ADD CONSTRAINT record_access_log_202711_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_202712 record_access_log_202712_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_202712
    ADD CONSTRAINT record_access_log_202712_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: record_access_log_default record_access_log_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.record_access_log_default
    ADD CONSTRAINT record_access_log_default_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: refresh_tokens refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id);


--
-- Name: scheduled_doses scheduled_doses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_doses
    ADD CONSTRAINT scheduled_doses_pkey PRIMARY KEY (id);


--
-- Name: shift_notes shift_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_notes
    ADD CONSTRAINT shift_notes_pkey PRIMARY KEY (id);


--
-- Name: sos_events sos_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sos_events
    ADD CONSTRAINT sos_events_pkey PRIMARY KEY (id);


--
-- Name: specialties specialties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.specialties
    ADD CONSTRAINT specialties_pkey PRIMARY KEY (code);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: support_articles support_articles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_articles
    ADD CONSTRAINT support_articles_pkey PRIMARY KEY (id);


--
-- Name: system_parameters system_parameters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_parameters
    ADD CONSTRAINT system_parameters_pkey PRIMARY KEY (key);


--
-- Name: treatment_documents treatment_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_documents
    ADD CONSTRAINT treatment_documents_pkey PRIMARY KEY (treatment_id, document_id);


--
-- Name: treatment_item_days treatment_item_days_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_days
    ADD CONSTRAINT treatment_item_days_pkey PRIMARY KEY (treatment_item_id, day_of_week);


--
-- Name: treatment_item_prn_uses treatment_item_prn_uses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_prn_uses
    ADD CONSTRAINT treatment_item_prn_uses_pkey PRIMARY KEY (id);


--
-- Name: treatment_item_times treatment_item_times_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_times
    ADD CONSTRAINT treatment_item_times_pkey PRIMARY KEY (id);


--
-- Name: treatment_items treatment_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_items
    ADD CONSTRAINT treatment_items_pkey PRIMARY KEY (id);


--
-- Name: treatments treatments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatments
    ADD CONSTRAINT treatments_pkey PRIMARY KEY (id);


--
-- Name: activity_reports uq_activity_reports_storage; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_reports
    ADD CONSTRAINT uq_activity_reports_storage UNIQUE (storage_key);


--
-- Name: alerts uq_alerts_id_patient; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT uq_alerts_id_patient UNIQUE (id, patient_id);


--
-- Name: billing_events uq_billing_events_provider; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT uq_billing_events_provider UNIQUE (provider_event_id);


--
-- Name: caregiver_certifications uq_caregiver_certifications_file; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_certifications
    ADD CONSTRAINT uq_caregiver_certifications_file UNIQUE (file_id);


--
-- Name: caregiver_profiles uq_caregiver_profiles_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_profiles
    ADD CONSTRAINT uq_caregiver_profiles_id_user UNIQUE (id, user_id);


--
-- Name: caregiver_profiles uq_caregiver_profiles_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_profiles
    ADD CONSTRAINT uq_caregiver_profiles_user UNIQUE (user_id);


--
-- Name: caregiver_reviews uq_caregiver_reviews_autor; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_reviews
    ADD CONSTRAINT uq_caregiver_reviews_autor UNIQUE (profile_id, author_id);


--
-- Name: chat_ws_sessions uq_chat_ws_sessions_user_patient; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_ws_sessions
    ADD CONSTRAINT uq_chat_ws_sessions_user_patient UNIQUE (user_id, patient_id);


--
-- Name: conversations uq_conversations_id_type; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT uq_conversations_id_type UNIQUE (id, type);


--
-- Name: creation_shares uq_creation_shares_creation_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creation_shares
    ADD CONSTRAINT uq_creation_shares_creation_user UNIQUE (music_creation_id, shared_with_user_id);


--
-- Name: creation_shares uq_creation_shares_token; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creation_shares
    ADD CONSTRAINT uq_creation_shares_token UNIQUE (token_hash);


--
-- Name: daily_checkins uq_daily_checkins_dia; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_checkins
    ADD CONSTRAINT uq_daily_checkins_dia UNIQUE (patient_id, checkin_date);


--
-- Name: device_link_codes uq_device_link_codes_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_link_codes
    ADD CONSTRAINT uq_device_link_codes_hash UNIQUE (code_hash);


--
-- Name: elder_devices uq_elder_devices_fingerprint; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT uq_elder_devices_fingerprint UNIQUE (device_fingerprint);


--
-- Name: elder_devices uq_elder_devices_link_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT uq_elder_devices_link_code UNIQUE (link_code_id);


--
-- Name: elder_devices uq_elder_devices_push; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT uq_elder_devices_push UNIQUE (push_token);


--
-- Name: elder_devices uq_elder_devices_session; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT uq_elder_devices_session UNIQUE (session_token_hash);


--
-- Name: files uq_files_id_patient; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT uq_files_id_patient UNIQUE (id, patient_id);


--
-- Name: files uq_files_id_scope; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT uq_files_id_scope UNIQUE (id, scope);


--
-- Name: files uq_files_storage_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT uq_files_storage_key UNIQUE (storage_key);


--
-- Name: idempotency_keys uq_idempotency_keys_usuario; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT uq_idempotency_keys_usuario UNIQUE (user_id, idem_key);


--
-- Name: incidents uq_incidents_alert; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT uq_incidents_alert UNIQUE (alert_id);


--
-- Name: medical_documents uq_medical_documents_file; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_documents
    ADD CONSTRAINT uq_medical_documents_file UNIQUE (file_id);


--
-- Name: medication_times uq_medication_times_slot; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medication_times
    ADD CONSTRAINT uq_medication_times_slot UNIQUE (medication_id, time_of_day);


--
-- Name: message_receipts uq_message_receipts_message_recipient; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_receipts
    ADD CONSTRAINT uq_message_receipts_message_recipient UNIQUE (message_id, recipient_id);


--
-- Name: music_creations uq_music_creations_client; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.music_creations
    ADD CONSTRAINT uq_music_creations_client UNIQUE (client_uuid);


--
-- Name: notification_settings uq_notification_settings_pair; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT uq_notification_settings_pair UNIQUE (user_id, alert_type);


--
-- Name: password_reset_tokens uq_password_reset_tokens_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT uq_password_reset_tokens_hash UNIQUE (token_hash);


--
-- Name: patient_members uq_patient_members_pair; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_members
    ADD CONSTRAINT uq_patient_members_pair UNIQUE (patient_id, user_id);


--
-- Name: photo_reactions uq_photo_reactions_photo_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.photo_reactions
    ADD CONSTRAINT uq_photo_reactions_photo_user UNIQUE (photo_id, user_id);


--
-- Name: plans uq_plans_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT uq_plans_code UNIQUE (code);


--
-- Name: scheduled_doses uq_scheduled_doses_slot; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_doses
    ADD CONSTRAINT uq_scheduled_doses_slot UNIQUE (medication_id, scheduled_at);


--
-- Name: shift_notes uq_shift_notes_turno; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_notes
    ADD CONSTRAINT uq_shift_notes_turno UNIQUE (patient_id, shift_date, shift);


--
-- Name: sos_events uq_sos_events_alert; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sos_events
    ADD CONSTRAINT uq_sos_events_alert UNIQUE (alert_id);


--
-- Name: treatment_item_times uq_treatment_item_times_slot; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_times
    ADD CONSTRAINT uq_treatment_item_times_slot UNIQUE (treatment_item_id, time_of_day);


--
-- Name: vital_readings uq_vital_readings_natural; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings
    ADD CONSTRAINT uq_vital_readings_natural UNIQUE (patient_id, type, measured_at, source);


--
-- Name: wellbeing_snapshots uq_wellbeing_snapshots_day; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wellbeing_snapshots
    ADD CONSTRAINT uq_wellbeing_snapshots_day UNIQUE (patient_id, snapshot_date);


--
-- Name: usage_counters usage_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_counters
    ADD CONSTRAINT usage_counters_pkey PRIMARY KEY (subscription_id, limit_key, period_start);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vaccine_catalog vaccine_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vaccine_catalog
    ADD CONSTRAINT vaccine_catalog_pkey PRIMARY KEY (code);


--
-- Name: vital_readings_2025_11 vital_readings_2025_11_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2025_11
    ADD CONSTRAINT vital_readings_2025_11_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2025_11 vital_readings_2025_11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2025_11
    ADD CONSTRAINT vital_readings_2025_11_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2025_12 vital_readings_2025_12_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2025_12
    ADD CONSTRAINT vital_readings_2025_12_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2025_12 vital_readings_2025_12_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2025_12
    ADD CONSTRAINT vital_readings_2025_12_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_01 vital_readings_2026_01_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_01
    ADD CONSTRAINT vital_readings_2026_01_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_01 vital_readings_2026_01_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_01
    ADD CONSTRAINT vital_readings_2026_01_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_02 vital_readings_2026_02_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_02
    ADD CONSTRAINT vital_readings_2026_02_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_02 vital_readings_2026_02_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_02
    ADD CONSTRAINT vital_readings_2026_02_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_03 vital_readings_2026_03_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_03
    ADD CONSTRAINT vital_readings_2026_03_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_03 vital_readings_2026_03_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_03
    ADD CONSTRAINT vital_readings_2026_03_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_04 vital_readings_2026_04_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_04
    ADD CONSTRAINT vital_readings_2026_04_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_04 vital_readings_2026_04_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_04
    ADD CONSTRAINT vital_readings_2026_04_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_05 vital_readings_2026_05_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_05
    ADD CONSTRAINT vital_readings_2026_05_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_05 vital_readings_2026_05_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_05
    ADD CONSTRAINT vital_readings_2026_05_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_06 vital_readings_2026_06_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_06
    ADD CONSTRAINT vital_readings_2026_06_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_06 vital_readings_2026_06_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_06
    ADD CONSTRAINT vital_readings_2026_06_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_07 vital_readings_2026_07_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_07
    ADD CONSTRAINT vital_readings_2026_07_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_07 vital_readings_2026_07_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_07
    ADD CONSTRAINT vital_readings_2026_07_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_08 vital_readings_2026_08_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_08
    ADD CONSTRAINT vital_readings_2026_08_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_08 vital_readings_2026_08_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_08
    ADD CONSTRAINT vital_readings_2026_08_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_09 vital_readings_2026_09_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_09
    ADD CONSTRAINT vital_readings_2026_09_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_09 vital_readings_2026_09_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_09
    ADD CONSTRAINT vital_readings_2026_09_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_10 vital_readings_2026_10_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_10
    ADD CONSTRAINT vital_readings_2026_10_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_10 vital_readings_2026_10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_10
    ADD CONSTRAINT vital_readings_2026_10_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_11 vital_readings_2026_11_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_11
    ADD CONSTRAINT vital_readings_2026_11_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_11 vital_readings_2026_11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_11
    ADD CONSTRAINT vital_readings_2026_11_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2026_12 vital_readings_2026_12_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_12
    ADD CONSTRAINT vital_readings_2026_12_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2026_12 vital_readings_2026_12_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2026_12
    ADD CONSTRAINT vital_readings_2026_12_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_01 vital_readings_2027_01_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_01
    ADD CONSTRAINT vital_readings_2027_01_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_01 vital_readings_2027_01_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_01
    ADD CONSTRAINT vital_readings_2027_01_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_02 vital_readings_2027_02_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_02
    ADD CONSTRAINT vital_readings_2027_02_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_02 vital_readings_2027_02_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_02
    ADD CONSTRAINT vital_readings_2027_02_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_03 vital_readings_2027_03_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_03
    ADD CONSTRAINT vital_readings_2027_03_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_03 vital_readings_2027_03_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_03
    ADD CONSTRAINT vital_readings_2027_03_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_04 vital_readings_2027_04_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_04
    ADD CONSTRAINT vital_readings_2027_04_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_04 vital_readings_2027_04_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_04
    ADD CONSTRAINT vital_readings_2027_04_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_05 vital_readings_2027_05_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_05
    ADD CONSTRAINT vital_readings_2027_05_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_05 vital_readings_2027_05_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_05
    ADD CONSTRAINT vital_readings_2027_05_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_06 vital_readings_2027_06_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_06
    ADD CONSTRAINT vital_readings_2027_06_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_06 vital_readings_2027_06_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_06
    ADD CONSTRAINT vital_readings_2027_06_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_07 vital_readings_2027_07_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_07
    ADD CONSTRAINT vital_readings_2027_07_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_07 vital_readings_2027_07_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_07
    ADD CONSTRAINT vital_readings_2027_07_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_08 vital_readings_2027_08_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_08
    ADD CONSTRAINT vital_readings_2027_08_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_08 vital_readings_2027_08_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_08
    ADD CONSTRAINT vital_readings_2027_08_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_09 vital_readings_2027_09_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_09
    ADD CONSTRAINT vital_readings_2027_09_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_09 vital_readings_2027_09_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_09
    ADD CONSTRAINT vital_readings_2027_09_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_10 vital_readings_2027_10_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_10
    ADD CONSTRAINT vital_readings_2027_10_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_10 vital_readings_2027_10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_10
    ADD CONSTRAINT vital_readings_2027_10_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_2027_11 vital_readings_2027_11_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_11
    ADD CONSTRAINT vital_readings_2027_11_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_2027_11 vital_readings_2027_11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_2027_11
    ADD CONSTRAINT vital_readings_2027_11_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_readings_default vital_readings_default_patient_id_type_measured_at_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_default
    ADD CONSTRAINT vital_readings_default_patient_id_type_measured_at_source_key UNIQUE (patient_id, type, measured_at, source);


--
-- Name: vital_readings_default vital_readings_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_readings_default
    ADD CONSTRAINT vital_readings_default_pkey PRIMARY KEY (id, measured_at);


--
-- Name: vital_thresholds vital_thresholds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_thresholds
    ADD CONSTRAINT vital_thresholds_pkey PRIMARY KEY (id);


--
-- Name: vital_types vital_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_types
    ADD CONSTRAINT vital_types_pkey PRIMARY KEY (code);


--
-- Name: wearables wearables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wearables
    ADD CONSTRAINT wearables_pkey PRIMARY KEY (id);


--
-- Name: wellbeing_snapshots wellbeing_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wellbeing_snapshots
    ADD CONSTRAINT wellbeing_snapshots_pkey PRIMARY KEY (id);


--
-- Name: ix_analytics_events_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_analytics_events_actor ON ONLY public.analytics_events USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202610_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202610_actor_user_id_occurred_at_idx ON public.analytics_events_202610 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: ix_analytics_events_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_analytics_events_name ON ONLY public.analytics_events USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202610_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202610_event_name_occurred_at_idx ON public.analytics_events_202610 USING btree (event_name, occurred_at DESC);


--
-- Name: ix_analytics_events_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_analytics_events_patient ON ONLY public.analytics_events USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202610_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202610_patient_id_occurred_at_idx ON public.analytics_events_202610 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: ix_analytics_events_properties; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_analytics_events_properties ON ONLY public.analytics_events USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202610_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202610_properties_idx ON public.analytics_events_202610 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202611_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202611_actor_user_id_occurred_at_idx ON public.analytics_events_202611 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202611_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202611_event_name_occurred_at_idx ON public.analytics_events_202611 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202611_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202611_patient_id_occurred_at_idx ON public.analytics_events_202611 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202611_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202611_properties_idx ON public.analytics_events_202611 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202612_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202612_actor_user_id_occurred_at_idx ON public.analytics_events_202612 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202612_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202612_event_name_occurred_at_idx ON public.analytics_events_202612 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202612_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202612_patient_id_occurred_at_idx ON public.analytics_events_202612 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202612_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202612_properties_idx ON public.analytics_events_202612 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202701_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202701_actor_user_id_occurred_at_idx ON public.analytics_events_202701 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202701_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202701_event_name_occurred_at_idx ON public.analytics_events_202701 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202701_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202701_patient_id_occurred_at_idx ON public.analytics_events_202701 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202701_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202701_properties_idx ON public.analytics_events_202701 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202702_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202702_actor_user_id_occurred_at_idx ON public.analytics_events_202702 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202702_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202702_event_name_occurred_at_idx ON public.analytics_events_202702 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202702_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202702_patient_id_occurred_at_idx ON public.analytics_events_202702 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202702_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202702_properties_idx ON public.analytics_events_202702 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202703_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202703_actor_user_id_occurred_at_idx ON public.analytics_events_202703 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202703_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202703_event_name_occurred_at_idx ON public.analytics_events_202703 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202703_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202703_patient_id_occurred_at_idx ON public.analytics_events_202703 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202703_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202703_properties_idx ON public.analytics_events_202703 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202704_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202704_actor_user_id_occurred_at_idx ON public.analytics_events_202704 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202704_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202704_event_name_occurred_at_idx ON public.analytics_events_202704 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202704_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202704_patient_id_occurred_at_idx ON public.analytics_events_202704 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202704_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202704_properties_idx ON public.analytics_events_202704 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202705_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202705_actor_user_id_occurred_at_idx ON public.analytics_events_202705 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202705_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202705_event_name_occurred_at_idx ON public.analytics_events_202705 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202705_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202705_patient_id_occurred_at_idx ON public.analytics_events_202705 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202705_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202705_properties_idx ON public.analytics_events_202705 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202706_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202706_actor_user_id_occurred_at_idx ON public.analytics_events_202706 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202706_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202706_event_name_occurred_at_idx ON public.analytics_events_202706 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202706_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202706_patient_id_occurred_at_idx ON public.analytics_events_202706 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202706_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202706_properties_idx ON public.analytics_events_202706 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202707_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202707_actor_user_id_occurred_at_idx ON public.analytics_events_202707 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202707_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202707_event_name_occurred_at_idx ON public.analytics_events_202707 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202707_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202707_patient_id_occurred_at_idx ON public.analytics_events_202707 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202707_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202707_properties_idx ON public.analytics_events_202707 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202708_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202708_actor_user_id_occurred_at_idx ON public.analytics_events_202708 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202708_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202708_event_name_occurred_at_idx ON public.analytics_events_202708 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202708_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202708_patient_id_occurred_at_idx ON public.analytics_events_202708 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202708_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202708_properties_idx ON public.analytics_events_202708 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202709_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202709_actor_user_id_occurred_at_idx ON public.analytics_events_202709 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202709_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202709_event_name_occurred_at_idx ON public.analytics_events_202709 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202709_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202709_patient_id_occurred_at_idx ON public.analytics_events_202709 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202709_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202709_properties_idx ON public.analytics_events_202709 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202710_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202710_actor_user_id_occurred_at_idx ON public.analytics_events_202710 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202710_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202710_event_name_occurred_at_idx ON public.analytics_events_202710 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202710_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202710_patient_id_occurred_at_idx ON public.analytics_events_202710 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202710_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202710_properties_idx ON public.analytics_events_202710 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202711_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202711_actor_user_id_occurred_at_idx ON public.analytics_events_202711 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202711_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202711_event_name_occurred_at_idx ON public.analytics_events_202711 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202711_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202711_patient_id_occurred_at_idx ON public.analytics_events_202711 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202711_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202711_properties_idx ON public.analytics_events_202711 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_202712_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202712_actor_user_id_occurred_at_idx ON public.analytics_events_202712 USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_202712_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202712_event_name_occurred_at_idx ON public.analytics_events_202712 USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_202712_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202712_patient_id_occurred_at_idx ON public.analytics_events_202712 USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_202712_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_202712_properties_idx ON public.analytics_events_202712 USING gin (properties jsonb_path_ops);


--
-- Name: analytics_events_default_actor_user_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_default_actor_user_id_occurred_at_idx ON public.analytics_events_default USING btree (actor_user_id, occurred_at DESC) WHERE (actor_user_id IS NOT NULL);


--
-- Name: analytics_events_default_event_name_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_default_event_name_occurred_at_idx ON public.analytics_events_default USING btree (event_name, occurred_at DESC);


--
-- Name: analytics_events_default_patient_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_default_patient_id_occurred_at_idx ON public.analytics_events_default USING btree (patient_id, occurred_at DESC) WHERE (patient_id IS NOT NULL);


--
-- Name: analytics_events_default_properties_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_default_properties_idx ON public.analytics_events_default USING gin (properties jsonb_path_ops);


--
-- Name: ix_activity_reports_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_reports_patient ON public.activity_reports USING btree (patient_id, period_to DESC);


--
-- Name: ix_activity_reports_pendientes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_reports_pendientes ON public.activity_reports USING btree (created_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: ix_activity_sessions_abiertas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_sessions_abiertas ON public.activity_sessions USING btree (started_at) WHERE (ended_at IS NULL);


--
-- Name: ix_activity_sessions_activity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_sessions_activity ON public.activity_sessions USING btree (activity, started_at DESC);


--
-- Name: ix_activity_sessions_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_sessions_patient ON public.activity_sessions USING btree (patient_id, started_at DESC);


--
-- Name: ix_admin_audit_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_admin_audit_fecha ON public.admin_audit_log USING btree (created_at DESC);


--
-- Name: ix_admin_audit_objetivo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_admin_audit_objetivo ON public.admin_audit_log USING btree (target_user_id, created_at DESC);


--
-- Name: ix_alert_deliveries_alert; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_alert_deliveries_alert ON public.alert_deliveries USING btree (alert_id);


--
-- Name: ix_alert_deliveries_failed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_alert_deliveries_failed ON public.alert_deliveries USING btree (created_at) WHERE ((status)::text = 'failed'::text);


--
-- Name: ix_alert_deliveries_queued; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_alert_deliveries_queued ON public.alert_deliveries USING btree (created_at) WHERE ((status)::text = 'queued'::text);


--
-- Name: ix_alerts_dedup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_alerts_dedup ON public.alerts USING btree (patient_id, dedup_key, created_at DESC) WHERE (dedup_key IS NOT NULL);


--
-- Name: ix_alerts_patient_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_alerts_patient_status ON public.alerts USING btree (patient_id, status, created_at DESC);


--
-- Name: ix_alerts_pending_critical; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_alerts_pending_critical ON public.alerts USING btree (created_at) WHERE (((status)::text = 'active'::text) AND ((severity)::text = 'critical'::text));


--
-- Name: ix_alerts_sin_avisar; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_alerts_sin_avisar ON public.alerts USING btree (created_at) WHERE (notified_at IS NULL);


--
-- Name: ix_assistant_citations_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_assistant_citations_source ON public.assistant_citations USING btree (source_table_name, source_record_id);


--
-- Name: ix_assistant_queries_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_assistant_queries_user ON public.assistant_queries USING btree (user_id, created_at DESC);


--
-- Name: ix_audit_log_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_audit_log_actor ON public.audit_log USING btree (actor_user_id, created_at DESC);


--
-- Name: ix_audit_log_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_audit_log_patient ON public.audit_log USING btree (patient_id, created_at DESC);


--
-- Name: ix_billing_events_fallidos; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_billing_events_fallidos ON public.billing_events USING btree (occurred_at DESC) WHERE ((status)::text = 'failed'::text);


--
-- Name: ix_billing_events_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_billing_events_subscription ON public.billing_events USING btree (subscription_id, occurred_at DESC);


--
-- Name: ix_care_observations_patient_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_care_observations_patient_category ON public.care_observations USING btree (patient_id, category, observed_at DESC) WHERE (deleted_at IS NULL);


--
-- Name: ix_care_observations_patient_observed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_care_observations_patient_observed ON public.care_observations USING btree (patient_id, observed_at DESC) WHERE (deleted_at IS NULL);


--
-- Name: ix_care_shifts_caregiver_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_care_shifts_caregiver_fecha ON public.care_shifts USING btree (caregiver_id, checked_in_at DESC);


--
-- Name: ix_care_shifts_patient_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_care_shifts_patient_fecha ON public.care_shifts USING btree (patient_id, checked_in_at DESC);


--
-- Name: ix_care_tasks_assigned_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_care_tasks_assigned_due ON public.care_tasks USING btree (assigned_to_user_id, due_date) WHERE (deleted_at IS NULL);


--
-- Name: ix_care_tasks_patient_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_care_tasks_patient_fecha ON public.care_tasks USING btree (patient_id, due_date DESC, due_time) WHERE (deleted_at IS NULL);


--
-- Name: ix_caregiver_certifications_perfil; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_caregiver_certifications_perfil ON public.caregiver_certifications USING btree (profile_id, expires_at DESC) WHERE (deleted_at IS NULL);


--
-- Name: ix_caregiver_certifications_por_verificar; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_caregiver_certifications_por_verificar ON public.caregiver_certifications USING btree (created_at) WHERE ((verified_at IS NULL) AND (deleted_at IS NULL));


--
-- Name: ix_caregiver_languages_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_caregiver_languages_code ON public.caregiver_languages USING btree (language_code, profile_id);


--
-- Name: ix_caregiver_profiles_busqueda; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_caregiver_profiles_busqueda ON public.caregiver_profiles USING btree (rating_avg DESC NULLS LAST, rating_count DESC) WHERE (((status)::text = 'published'::text) AND (deleted_at IS NULL));


--
-- Name: ix_caregiver_reviews_perfil; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_caregiver_reviews_perfil ON public.caregiver_reviews USING btree (profile_id, created_at DESC) WHERE (deleted_at IS NULL);


--
-- Name: ix_caregiver_specialties_specialty; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_caregiver_specialties_specialty ON public.caregiver_specialties USING btree (specialty_code, profile_id);


--
-- Name: ix_caregiver_zones_comuna; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_caregiver_zones_comuna ON public.caregiver_zones USING btree (commune_code, profile_id);


--
-- Name: ix_chat_ws_sessions_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_ws_sessions_patient ON public.chat_ws_sessions USING btree (patient_id);


--
-- Name: ix_contact_requests_perfil; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_contact_requests_perfil ON public.contact_requests USING btree (profile_id, created_at DESC);


--
-- Name: ix_contact_requests_solicitante; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_contact_requests_solicitante ON public.contact_requests USING btree (requester_id, created_at DESC);


--
-- Name: ix_content_playbacks_patient_started; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_content_playbacks_patient_started ON public.content_playbacks USING btree (patient_id, started_at DESC);


--
-- Name: ix_conversations_asistente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_conversations_asistente ON public.conversations USING btree (patient_id, user_id, last_message_at DESC) WHERE ((type)::text = 'assistant'::text);


--
-- Name: ix_conversations_patient_last_msg; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_conversations_patient_last_msg ON public.conversations USING btree (patient_id, last_message_at DESC);


--
-- Name: ix_creation_shares_enlaces; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_creation_shares_enlaces ON public.creation_shares USING btree (music_creation_id, expires_at DESC) WHERE ((token_hash IS NOT NULL) AND (revoked_at IS NULL));


--
-- Name: ix_creation_shares_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_creation_shares_user ON public.creation_shares USING btree (shared_with_user_id);


--
-- Name: ix_daily_checkins_malos; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_daily_checkins_malos ON public.daily_checkins USING btree (patient_id, checkin_date DESC) WHERE ((mood)::text = 'bad'::text);


--
-- Name: ix_daily_checkins_patient_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_daily_checkins_patient_fecha ON public.daily_checkins USING btree (patient_id, checkin_date DESC);


--
-- Name: ix_device_link_codes_vigentes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_device_link_codes_vigentes ON public.device_link_codes USING btree (patient_id, expires_at DESC) WHERE ((used_at IS NULL) AND (revoked_at IS NULL));


--
-- Name: ix_elder_devices_patient_activos; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_elder_devices_patient_activos ON public.elder_devices USING btree (patient_id, last_seen_at DESC) WHERE (unlinked_at IS NULL);


--
-- Name: ix_elder_devices_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_elder_devices_user ON public.elder_devices USING btree (user_id) WHERE (unlinked_at IS NULL);


--
-- Name: ix_elder_feed_items_publicado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_elder_feed_items_publicado ON public.elder_feed_items USING btree (type, published_at DESC) WHERE (((status)::text = 'published'::text) AND (deleted_at IS NULL));


--
-- Name: ix_features_module; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_features_module ON public.features USING btree (module, code);


--
-- Name: ix_file_ocr_busqueda; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_file_ocr_busqueda ON public.file_ocr USING gin (to_tsvector('spanish'::regconfig, texto));


--
-- Name: ix_files_patient_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_files_patient_created ON public.files USING btree (patient_id, created_at DESC);


--
-- Name: ix_files_pending_expired; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_files_pending_expired ON public.files USING btree (upload_expires_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: ix_files_pending_vencidas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_files_pending_vencidas ON public.files USING btree (upload_expires_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: ix_files_user_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_files_user_scope ON public.files USING btree (uploaded_by) WHERE ((scope)::text = 'user'::text);


--
-- Name: ix_gallery_photos_patient_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_gallery_photos_patient_order ON public.gallery_photos USING btree (patient_id, display_order) WHERE (deleted_at IS NULL);


--
-- Name: ix_idempotency_keys_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_idempotency_keys_created ON public.idempotency_keys USING btree (created_at);


--
-- Name: ix_incidents_patient_occurred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_incidents_patient_occurred ON public.incidents USING btree (patient_id, occurred_at DESC);


--
-- Name: ix_incidents_severe; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_incidents_severe ON public.incidents USING btree (patient_id, occurred_at DESC) WHERE ((severity)::text = ANY ((ARRAY['high'::character varying, 'critical'::character varying])::text[]));


--
-- Name: ix_invitations_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invitations_patient ON public.invitations USING btree (patient_id);


--
-- Name: ix_job_offers_abiertas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_job_offers_abiertas ON public.job_offers USING btree (published_at DESC) WHERE (((status)::text = 'published'::text) AND (deleted_at IS NULL));


--
-- Name: ix_job_offers_comuna; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_job_offers_comuna ON public.job_offers USING btree (commune_code, published_at DESC) WHERE (((status)::text = 'published'::text) AND (deleted_at IS NULL));


--
-- Name: ix_market_products_catalogo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_market_products_catalogo ON public.market_products USING btree (category, name) WHERE (((status)::text = 'published'::text) AND (deleted_at IS NULL));


--
-- Name: ix_medical_documents_patient_categoria; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_medical_documents_patient_categoria ON public.medical_documents USING btree (patient_id, category, document_date DESC) WHERE (deleted_at IS NULL);


--
-- Name: ix_medical_documents_patient_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_medical_documents_patient_fecha ON public.medical_documents USING btree (patient_id, created_at DESC) WHERE (deleted_at IS NULL);


--
-- Name: ix_medical_documents_por_depurar; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_medical_documents_por_depurar ON public.medical_documents USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: ix_medication_times_medication; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_medication_times_medication ON public.medication_times USING btree (medication_id);


--
-- Name: ix_medications_patient_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_medications_patient_active ON public.medications USING btree (patient_id) WHERE (discontinued_at IS NULL);


--
-- Name: ix_message_receipts_undelivered; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_message_receipts_undelivered ON public.message_receipts USING btree (recipient_id) WHERE (delivered_at IS NULL);


--
-- Name: ix_message_receipts_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_message_receipts_unread ON public.message_receipts USING btree (recipient_id) WHERE (read_at IS NULL);


--
-- Name: ix_messages_conversation_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_messages_conversation_created ON public.messages USING btree (conversation_id, created_at);


--
-- Name: ix_music_creations_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_music_creations_patient ON public.music_creations USING btree (patient_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_password_reset_tokens_hash_activo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_password_reset_tokens_hash_activo ON public.password_reset_tokens USING btree (token_hash) WHERE (used_at IS NULL);


--
-- Name: ix_password_reset_tokens_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_password_reset_tokens_user ON public.password_reset_tokens USING btree (user_id, created_at DESC);


--
-- Name: ix_patient_allergies_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_patient_allergies_patient ON public.patient_allergies USING btree (patient_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_patient_conditions_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_patient_conditions_patient ON public.patient_conditions USING btree (patient_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_patient_immunizations_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_patient_immunizations_due ON public.patient_immunizations USING btree (next_due_on) WHERE ((deleted_at IS NULL) AND (next_due_on IS NOT NULL));


--
-- Name: ix_patient_immunizations_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_patient_immunizations_patient ON public.patient_immunizations USING btree (patient_id, administered_on DESC) WHERE (deleted_at IS NULL);


--
-- Name: ix_patient_measurements_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_patient_measurements_patient ON public.patient_measurements USING btree (patient_id, measured_at DESC);


--
-- Name: ix_patient_members_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_patient_members_user ON public.patient_members USING btree (user_id) WHERE (removed_at IS NULL);


--
-- Name: ix_patients_full_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_patients_full_name ON public.patients USING btree (lower((full_name)::text)) WHERE (deleted_at IS NULL);


--
-- Name: ix_photo_reactions_photo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_photo_reactions_photo ON public.photo_reactions USING btree (photo_id);


--
-- Name: ix_plan_features_feature; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_plan_features_feature ON public.plan_features USING btree (feature_code) WHERE is_included;


--
-- Name: ix_plan_prices_vigentes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_plan_prices_vigentes ON public.plan_prices USING btree (plan_id, currency, period, valid_from DESC) WHERE (valid_to IS NULL);


--
-- Name: ix_plans_publicos; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_plans_publicos ON public.plans USING btree (tier) WHERE (((status)::text = 'active'::text) AND is_public);


--
-- Name: ix_prn_uses_item_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_prn_uses_item_time ON public.treatment_item_prn_uses USING btree (treatment_item_id, administered_at DESC);


--
-- Name: ix_push_devices_user_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_push_devices_user_active ON public.push_devices USING btree (user_id) WHERE is_active;


--
-- Name: ix_record_access_log_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_record_access_log_patient ON ONLY public.record_access_log USING btree (patient_id, accessed_at DESC);


--
-- Name: ix_record_access_log_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_record_access_log_user ON ONLY public.record_access_log USING btree (user_id, accessed_at DESC);


--
-- Name: ix_refresh_tokens_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_refresh_tokens_expires ON public.refresh_tokens USING btree (expires_at);


--
-- Name: ix_refresh_tokens_family; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_refresh_tokens_family ON public.refresh_tokens USING btree (family_id);


--
-- Name: ix_refresh_tokens_user_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_refresh_tokens_user_active ON public.refresh_tokens USING btree (user_id) WHERE (revoked_at IS NULL);


--
-- Name: ix_scheduled_doses_cancelables; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_scheduled_doses_cancelables ON public.scheduled_doses USING btree (scheduled_at) WHERE ((status)::text = ANY ((ARRAY['pending'::character varying, 'postponed'::character varying])::text[]));


--
-- Name: ix_scheduled_doses_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_scheduled_doses_item ON public.scheduled_doses USING btree (treatment_item_id) WHERE (treatment_item_id IS NOT NULL);


--
-- Name: ix_scheduled_doses_medication_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_scheduled_doses_medication_time ON public.scheduled_doses USING btree (medication_id, scheduled_at DESC);


--
-- Name: ix_scheduled_doses_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_scheduled_doses_pending ON public.scheduled_doses USING btree (scheduled_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: ix_shift_notes_patient_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_shift_notes_patient_fecha ON public.shift_notes USING btree (patient_id, shift_date DESC, shift) WHERE (deleted_at IS NULL);


--
-- Name: ix_shift_notes_sin_acuse; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_shift_notes_sin_acuse ON public.shift_notes USING btree (handover_to, shift_date DESC) WHERE ((acknowledged_at IS NULL) AND (deleted_at IS NULL));


--
-- Name: ix_sos_events_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sos_events_patient ON public.sos_events USING btree (patient_id, created_at DESC);


--
-- Name: ix_subscriptions_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_plan_id ON public.subscriptions USING btree (plan_id, status);


--
-- Name: ix_subscriptions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_user ON public.subscriptions USING btree (user_id, created_at DESC);


--
-- Name: ix_support_articles_categoria; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_support_articles_categoria ON public.support_articles USING btree (category, display_order) WHERE (deleted_at IS NULL);


--
-- Name: ix_support_articles_destacados; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_support_articles_destacados ON public.support_articles USING btree (display_order) WHERE (is_featured AND (deleted_at IS NULL));


--
-- Name: ix_treatment_item_times_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_treatment_item_times_item ON public.treatment_item_times USING btree (treatment_item_id);


--
-- Name: ix_treatment_items_continues; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_treatment_items_continues ON public.treatment_items USING btree (continues_item_id) WHERE (continues_item_id IS NOT NULL);


--
-- Name: ix_treatment_items_treatment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_treatment_items_treatment ON public.treatment_items USING btree (treatment_id);


--
-- Name: ix_treatments_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_treatments_patient ON public.treatments USING btree (patient_id, effective_from DESC);


--
-- Name: ix_treatments_patient_specialty; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_treatments_patient_specialty ON public.treatments USING btree (patient_id, specialty, effective_from DESC);


--
-- Name: ix_usage_counters_periodo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_usage_counters_periodo ON public.usage_counters USING btree (subscription_id, period_start DESC);


--
-- Name: ix_users_desactivados; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_users_desactivados ON public.users USING btree (deactivated_at) WHERE (deactivated_at IS NOT NULL);


--
-- Name: ix_users_staff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_users_staff ON public.users USING btree (email) WHERE (is_staff AND (deleted_at IS NULL));


--
-- Name: ix_vital_readings_series; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_vital_readings_series ON ONLY public.vital_readings USING btree (patient_id, type, measured_at DESC);


--
-- Name: ix_wearables_last_sync; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_wearables_last_sync ON public.wearables USING btree (last_sync_at) WHERE (unlinked_at IS NULL);


--
-- Name: ix_wellbeing_snapshots_patient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_wellbeing_snapshots_patient ON public.wellbeing_snapshots USING btree (patient_id, snapshot_date DESC);


--
-- Name: record_access_log_202610_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202610_patient_id_accessed_at_idx ON public.record_access_log_202610 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202610_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202610_user_id_accessed_at_idx ON public.record_access_log_202610 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202611_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202611_patient_id_accessed_at_idx ON public.record_access_log_202611 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202611_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202611_user_id_accessed_at_idx ON public.record_access_log_202611 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202612_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202612_patient_id_accessed_at_idx ON public.record_access_log_202612 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202612_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202612_user_id_accessed_at_idx ON public.record_access_log_202612 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202701_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202701_patient_id_accessed_at_idx ON public.record_access_log_202701 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202701_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202701_user_id_accessed_at_idx ON public.record_access_log_202701 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202702_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202702_patient_id_accessed_at_idx ON public.record_access_log_202702 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202702_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202702_user_id_accessed_at_idx ON public.record_access_log_202702 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202703_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202703_patient_id_accessed_at_idx ON public.record_access_log_202703 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202703_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202703_user_id_accessed_at_idx ON public.record_access_log_202703 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202704_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202704_patient_id_accessed_at_idx ON public.record_access_log_202704 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202704_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202704_user_id_accessed_at_idx ON public.record_access_log_202704 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202705_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202705_patient_id_accessed_at_idx ON public.record_access_log_202705 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202705_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202705_user_id_accessed_at_idx ON public.record_access_log_202705 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202706_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202706_patient_id_accessed_at_idx ON public.record_access_log_202706 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202706_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202706_user_id_accessed_at_idx ON public.record_access_log_202706 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202707_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202707_patient_id_accessed_at_idx ON public.record_access_log_202707 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202707_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202707_user_id_accessed_at_idx ON public.record_access_log_202707 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202708_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202708_patient_id_accessed_at_idx ON public.record_access_log_202708 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202708_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202708_user_id_accessed_at_idx ON public.record_access_log_202708 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202709_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202709_patient_id_accessed_at_idx ON public.record_access_log_202709 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202709_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202709_user_id_accessed_at_idx ON public.record_access_log_202709 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202710_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202710_patient_id_accessed_at_idx ON public.record_access_log_202710 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202710_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202710_user_id_accessed_at_idx ON public.record_access_log_202710 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202711_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202711_patient_id_accessed_at_idx ON public.record_access_log_202711 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202711_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202711_user_id_accessed_at_idx ON public.record_access_log_202711 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_202712_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202712_patient_id_accessed_at_idx ON public.record_access_log_202712 USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_202712_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_202712_user_id_accessed_at_idx ON public.record_access_log_202712 USING btree (user_id, accessed_at DESC);


--
-- Name: record_access_log_default_patient_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_default_patient_id_accessed_at_idx ON public.record_access_log_default USING btree (patient_id, accessed_at DESC);


--
-- Name: record_access_log_default_user_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX record_access_log_default_user_id_accessed_at_idx ON public.record_access_log_default USING btree (user_id, accessed_at DESC);


--
-- Name: uq_care_shifts_abierto; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_care_shifts_abierto ON public.care_shifts USING btree (caregiver_id) WHERE (checked_out_at IS NULL);


--
-- Name: uq_plans_gratuito_activo; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_plans_gratuito_activo ON public.plans USING btree (tier) WHERE ((tier = 0) AND ((status)::text = 'active'::text));


--
-- Name: uq_scheduled_doses_item_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_scheduled_doses_item_slot ON public.scheduled_doses USING btree (treatment_item_id, scheduled_at) WHERE (treatment_item_id IS NOT NULL);


--
-- Name: uq_vital_thresholds_patient_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_vital_thresholds_patient_type ON public.vital_thresholds USING btree (patient_id, type) WHERE (deleted_at IS NULL);


--
-- Name: ux_alerts_dose; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_alerts_dose ON public.alerts USING btree (dose_id, type) WHERE (dose_id IS NOT NULL);


--
-- Name: ux_alerts_reading; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_alerts_reading ON public.alerts USING btree (reading_id) WHERE (reading_id IS NOT NULL);


--
-- Name: ux_contact_requests_pendiente; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_contact_requests_pendiente ON public.contact_requests USING btree (profile_id, requester_id) WHERE ((status)::text = 'pending'::text);


--
-- Name: ux_conversations_assistant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_conversations_assistant ON public.conversations USING btree (patient_id, user_id) WHERE ((type)::text = 'assistant'::text);


--
-- Name: ux_conversations_human; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_conversations_human ON public.conversations USING btree (patient_id) WHERE ((type)::text = 'human'::text);


--
-- Name: ux_doctor_enrollments_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_doctor_enrollments_token ON public.doctor_enrollments USING btree (token_hash);


--
-- Name: ux_doctor_profiles_license; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_doctor_profiles_license ON public.doctor_profiles USING btree (upper((license_number)::text)) WHERE (revoked_at IS NULL);


--
-- Name: ux_emergency_contacts_member; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_emergency_contacts_member ON public.emergency_contacts USING btree (patient_id, member_user_id) WHERE ((deleted_at IS NULL) AND (member_user_id IS NOT NULL));


--
-- Name: ux_invitations_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_invitations_pending ON public.invitations USING btree (patient_id, lower((email)::text)) WHERE ((accepted_at IS NULL) AND (revoked_at IS NULL) AND (email IS NOT NULL));


--
-- Name: ux_invitations_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_invitations_token ON public.invitations USING btree (token_hash) WHERE ((accepted_at IS NULL) AND (revoked_at IS NULL));


--
-- Name: ux_patient_allergy; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_patient_allergy ON public.patient_allergies USING btree (patient_id, substance) WHERE (deleted_at IS NULL);


--
-- Name: ux_patient_condition; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_patient_condition ON public.patient_conditions USING btree (patient_id, condition) WHERE (deleted_at IS NULL);


--
-- Name: ux_patient_members_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_patient_members_owner ON public.patient_members USING btree (patient_id) WHERE is_owner;


--
-- Name: ux_patients_rut; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_patients_rut ON public.patients USING btree (rut_number) WHERE ((deleted_at IS NULL) AND (rut_number IS NOT NULL));


--
-- Name: ux_push_devices_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_push_devices_token ON public.push_devices USING btree (push_token);


--
-- Name: ux_refresh_tokens_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_refresh_tokens_hash ON public.refresh_tokens USING btree (token_hash);


--
-- Name: ux_subscriptions_active_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_subscriptions_active_user ON public.subscriptions USING btree (user_id) WHERE ((status)::text = 'active'::text);


--
-- Name: ux_support_articles_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_support_articles_nombre ON public.support_articles USING btree (category, lower((name)::text)) WHERE (deleted_at IS NULL);


--
-- Name: ux_treatments_vigente_especialidad; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_treatments_vigente_especialidad ON public.treatments USING btree (patient_id, specialty) WHERE ((status)::text = 'vigente'::text);


--
-- Name: ux_users_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_users_email_lower ON public.users USING btree (lower((email)::text));


--
-- Name: ux_users_rut; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_users_rut ON public.users USING btree (rut_number) WHERE (rut_number IS NOT NULL);


--
-- Name: ux_wearables_patient_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_wearables_patient_active ON public.wearables USING btree (patient_id) WHERE (unlinked_at IS NULL);


--
-- Name: ux_wearables_serial_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_wearables_serial_active ON public.wearables USING btree (provider, serial_number) WHERE (unlinked_at IS NULL);


--
-- Name: vital_readings_2025_11_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2025_11_patient_id_type_measured_at_idx ON public.vital_readings_2025_11 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2025_12_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2025_12_patient_id_type_measured_at_idx ON public.vital_readings_2025_12 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_01_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_01_patient_id_type_measured_at_idx ON public.vital_readings_2026_01 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_02_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_02_patient_id_type_measured_at_idx ON public.vital_readings_2026_02 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_03_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_03_patient_id_type_measured_at_idx ON public.vital_readings_2026_03 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_04_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_04_patient_id_type_measured_at_idx ON public.vital_readings_2026_04 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_05_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_05_patient_id_type_measured_at_idx ON public.vital_readings_2026_05 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_06_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_06_patient_id_type_measured_at_idx ON public.vital_readings_2026_06 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_07_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_07_patient_id_type_measured_at_idx ON public.vital_readings_2026_07 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_08_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_08_patient_id_type_measured_at_idx ON public.vital_readings_2026_08 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_09_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_09_patient_id_type_measured_at_idx ON public.vital_readings_2026_09 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_10_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_10_patient_id_type_measured_at_idx ON public.vital_readings_2026_10 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_11_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_11_patient_id_type_measured_at_idx ON public.vital_readings_2026_11 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2026_12_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2026_12_patient_id_type_measured_at_idx ON public.vital_readings_2026_12 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_01_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_01_patient_id_type_measured_at_idx ON public.vital_readings_2027_01 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_02_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_02_patient_id_type_measured_at_idx ON public.vital_readings_2027_02 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_03_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_03_patient_id_type_measured_at_idx ON public.vital_readings_2027_03 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_04_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_04_patient_id_type_measured_at_idx ON public.vital_readings_2027_04 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_05_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_05_patient_id_type_measured_at_idx ON public.vital_readings_2027_05 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_06_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_06_patient_id_type_measured_at_idx ON public.vital_readings_2027_06 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_07_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_07_patient_id_type_measured_at_idx ON public.vital_readings_2027_07 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_08_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_08_patient_id_type_measured_at_idx ON public.vital_readings_2027_08 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_09_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_09_patient_id_type_measured_at_idx ON public.vital_readings_2027_09 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_10_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_10_patient_id_type_measured_at_idx ON public.vital_readings_2027_10 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_2027_11_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_2027_11_patient_id_type_measured_at_idx ON public.vital_readings_2027_11 USING btree (patient_id, type, measured_at DESC);


--
-- Name: vital_readings_default_patient_id_type_measured_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vital_readings_default_patient_id_type_measured_at_idx ON public.vital_readings_default USING btree (patient_id, type, measured_at DESC);


--
-- Name: analytics_events_202610_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202610_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202610_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202610_event_name_occurred_at_idx;


--
-- Name: analytics_events_202610_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202610_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202610_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202610_pkey;


--
-- Name: analytics_events_202610_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202610_properties_idx;


--
-- Name: analytics_events_202611_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202611_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202611_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202611_event_name_occurred_at_idx;


--
-- Name: analytics_events_202611_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202611_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202611_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202611_pkey;


--
-- Name: analytics_events_202611_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202611_properties_idx;


--
-- Name: analytics_events_202612_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202612_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202612_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202612_event_name_occurred_at_idx;


--
-- Name: analytics_events_202612_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202612_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202612_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202612_pkey;


--
-- Name: analytics_events_202612_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202612_properties_idx;


--
-- Name: analytics_events_202701_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202701_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202701_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202701_event_name_occurred_at_idx;


--
-- Name: analytics_events_202701_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202701_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202701_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202701_pkey;


--
-- Name: analytics_events_202701_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202701_properties_idx;


--
-- Name: analytics_events_202702_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202702_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202702_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202702_event_name_occurred_at_idx;


--
-- Name: analytics_events_202702_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202702_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202702_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202702_pkey;


--
-- Name: analytics_events_202702_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202702_properties_idx;


--
-- Name: analytics_events_202703_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202703_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202703_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202703_event_name_occurred_at_idx;


--
-- Name: analytics_events_202703_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202703_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202703_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202703_pkey;


--
-- Name: analytics_events_202703_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202703_properties_idx;


--
-- Name: analytics_events_202704_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202704_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202704_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202704_event_name_occurred_at_idx;


--
-- Name: analytics_events_202704_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202704_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202704_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202704_pkey;


--
-- Name: analytics_events_202704_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202704_properties_idx;


--
-- Name: analytics_events_202705_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202705_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202705_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202705_event_name_occurred_at_idx;


--
-- Name: analytics_events_202705_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202705_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202705_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202705_pkey;


--
-- Name: analytics_events_202705_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202705_properties_idx;


--
-- Name: analytics_events_202706_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202706_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202706_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202706_event_name_occurred_at_idx;


--
-- Name: analytics_events_202706_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202706_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202706_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202706_pkey;


--
-- Name: analytics_events_202706_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202706_properties_idx;


--
-- Name: analytics_events_202707_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202707_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202707_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202707_event_name_occurred_at_idx;


--
-- Name: analytics_events_202707_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202707_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202707_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202707_pkey;


--
-- Name: analytics_events_202707_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202707_properties_idx;


--
-- Name: analytics_events_202708_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202708_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202708_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202708_event_name_occurred_at_idx;


--
-- Name: analytics_events_202708_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202708_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202708_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202708_pkey;


--
-- Name: analytics_events_202708_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202708_properties_idx;


--
-- Name: analytics_events_202709_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202709_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202709_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202709_event_name_occurred_at_idx;


--
-- Name: analytics_events_202709_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202709_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202709_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202709_pkey;


--
-- Name: analytics_events_202709_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202709_properties_idx;


--
-- Name: analytics_events_202710_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202710_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202710_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202710_event_name_occurred_at_idx;


--
-- Name: analytics_events_202710_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202710_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202710_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202710_pkey;


--
-- Name: analytics_events_202710_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202710_properties_idx;


--
-- Name: analytics_events_202711_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202711_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202711_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202711_event_name_occurred_at_idx;


--
-- Name: analytics_events_202711_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202711_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202711_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202711_pkey;


--
-- Name: analytics_events_202711_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202711_properties_idx;


--
-- Name: analytics_events_202712_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_202712_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_202712_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_202712_event_name_occurred_at_idx;


--
-- Name: analytics_events_202712_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_202712_patient_id_occurred_at_idx;


--
-- Name: analytics_events_202712_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_202712_pkey;


--
-- Name: analytics_events_202712_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_202712_properties_idx;


--
-- Name: analytics_events_default_actor_user_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_actor ATTACH PARTITION public.analytics_events_default_actor_user_id_occurred_at_idx;


--
-- Name: analytics_events_default_event_name_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_name ATTACH PARTITION public.analytics_events_default_event_name_occurred_at_idx;


--
-- Name: analytics_events_default_patient_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_patient ATTACH PARTITION public.analytics_events_default_patient_id_occurred_at_idx;


--
-- Name: analytics_events_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.analytics_events_pkey ATTACH PARTITION public.analytics_events_default_pkey;


--
-- Name: analytics_events_default_properties_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_analytics_events_properties ATTACH PARTITION public.analytics_events_default_properties_idx;


--
-- Name: record_access_log_202610_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202610_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202610_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202610_pkey;


--
-- Name: record_access_log_202610_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202610_user_id_accessed_at_idx;


--
-- Name: record_access_log_202611_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202611_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202611_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202611_pkey;


--
-- Name: record_access_log_202611_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202611_user_id_accessed_at_idx;


--
-- Name: record_access_log_202612_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202612_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202612_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202612_pkey;


--
-- Name: record_access_log_202612_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202612_user_id_accessed_at_idx;


--
-- Name: record_access_log_202701_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202701_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202701_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202701_pkey;


--
-- Name: record_access_log_202701_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202701_user_id_accessed_at_idx;


--
-- Name: record_access_log_202702_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202702_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202702_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202702_pkey;


--
-- Name: record_access_log_202702_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202702_user_id_accessed_at_idx;


--
-- Name: record_access_log_202703_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202703_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202703_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202703_pkey;


--
-- Name: record_access_log_202703_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202703_user_id_accessed_at_idx;


--
-- Name: record_access_log_202704_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202704_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202704_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202704_pkey;


--
-- Name: record_access_log_202704_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202704_user_id_accessed_at_idx;


--
-- Name: record_access_log_202705_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202705_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202705_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202705_pkey;


--
-- Name: record_access_log_202705_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202705_user_id_accessed_at_idx;


--
-- Name: record_access_log_202706_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202706_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202706_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202706_pkey;


--
-- Name: record_access_log_202706_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202706_user_id_accessed_at_idx;


--
-- Name: record_access_log_202707_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202707_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202707_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202707_pkey;


--
-- Name: record_access_log_202707_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202707_user_id_accessed_at_idx;


--
-- Name: record_access_log_202708_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202708_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202708_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202708_pkey;


--
-- Name: record_access_log_202708_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202708_user_id_accessed_at_idx;


--
-- Name: record_access_log_202709_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202709_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202709_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202709_pkey;


--
-- Name: record_access_log_202709_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202709_user_id_accessed_at_idx;


--
-- Name: record_access_log_202710_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202710_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202710_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202710_pkey;


--
-- Name: record_access_log_202710_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202710_user_id_accessed_at_idx;


--
-- Name: record_access_log_202711_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202711_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202711_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202711_pkey;


--
-- Name: record_access_log_202711_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202711_user_id_accessed_at_idx;


--
-- Name: record_access_log_202712_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_202712_patient_id_accessed_at_idx;


--
-- Name: record_access_log_202712_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_202712_pkey;


--
-- Name: record_access_log_202712_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_202712_user_id_accessed_at_idx;


--
-- Name: record_access_log_default_patient_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_patient ATTACH PARTITION public.record_access_log_default_patient_id_accessed_at_idx;


--
-- Name: record_access_log_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.record_access_log_pkey ATTACH PARTITION public.record_access_log_default_pkey;


--
-- Name: record_access_log_default_user_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_record_access_log_user ATTACH PARTITION public.record_access_log_default_user_id_accessed_at_idx;


--
-- Name: vital_readings_2025_11_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2025_11_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2025_11_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2025_11_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2025_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2025_11_pkey;


--
-- Name: vital_readings_2025_12_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2025_12_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2025_12_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2025_12_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2025_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2025_12_pkey;


--
-- Name: vital_readings_2026_01_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_01_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_01_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_01_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_01_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_01_pkey;


--
-- Name: vital_readings_2026_02_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_02_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_02_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_02_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_02_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_02_pkey;


--
-- Name: vital_readings_2026_03_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_03_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_03_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_03_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_03_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_03_pkey;


--
-- Name: vital_readings_2026_04_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_04_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_04_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_04_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_04_pkey;


--
-- Name: vital_readings_2026_05_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_05_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_05_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_05_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_05_pkey;


--
-- Name: vital_readings_2026_06_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_06_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_06_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_06_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_06_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_06_pkey;


--
-- Name: vital_readings_2026_07_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_07_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_07_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_07_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_07_pkey;


--
-- Name: vital_readings_2026_08_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_08_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_08_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_08_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_08_pkey;


--
-- Name: vital_readings_2026_09_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_09_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_09_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_09_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_09_pkey;


--
-- Name: vital_readings_2026_10_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_10_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_10_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_10_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_10_pkey;


--
-- Name: vital_readings_2026_11_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_11_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_11_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_11_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_11_pkey;


--
-- Name: vital_readings_2026_12_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2026_12_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2026_12_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2026_12_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2026_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2026_12_pkey;


--
-- Name: vital_readings_2027_01_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_01_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_01_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_01_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_01_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_01_pkey;


--
-- Name: vital_readings_2027_02_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_02_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_02_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_02_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_02_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_02_pkey;


--
-- Name: vital_readings_2027_03_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_03_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_03_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_03_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_03_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_03_pkey;


--
-- Name: vital_readings_2027_04_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_04_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_04_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_04_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_04_pkey;


--
-- Name: vital_readings_2027_05_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_05_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_05_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_05_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_05_pkey;


--
-- Name: vital_readings_2027_06_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_06_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_06_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_06_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_06_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_06_pkey;


--
-- Name: vital_readings_2027_07_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_07_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_07_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_07_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_07_pkey;


--
-- Name: vital_readings_2027_08_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_08_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_08_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_08_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_08_pkey;


--
-- Name: vital_readings_2027_09_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_09_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_09_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_09_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_09_pkey;


--
-- Name: vital_readings_2027_10_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_10_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_10_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_10_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_10_pkey;


--
-- Name: vital_readings_2027_11_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_2027_11_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_2027_11_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_2027_11_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_2027_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_2027_11_pkey;


--
-- Name: vital_readings_default_patient_id_type_measured_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.ix_vital_readings_series ATTACH PARTITION public.vital_readings_default_patient_id_type_measured_at_idx;


--
-- Name: vital_readings_default_patient_id_type_measured_at_source_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.uq_vital_readings_natural ATTACH PARTITION public.vital_readings_default_patient_id_type_measured_at_source_key;


--
-- Name: vital_readings_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.pk_vital_readings ATTACH PARTITION public.vital_readings_default_pkey;


--
-- Name: activity_reports tg_activity_reports_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_activity_reports_updated_at BEFORE UPDATE ON public.activity_reports FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: alerts tg_alerts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_alerts_updated_at BEFORE UPDATE ON public.alerts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: analytics_events tg_analytics_events_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_analytics_events_no_update BEFORE DELETE OR UPDATE ON public.analytics_events FOR EACH ROW EXECUTE FUNCTION public.analytics_events_block_mutation();


--
-- Name: audit_log tg_audit_log_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_audit_log_no_update BEFORE DELETE OR UPDATE ON public.audit_log FOR EACH ROW EXECUTE FUNCTION public.audit_log_block_mutation();


--
-- Name: care_observations tg_care_observations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_care_observations_updated_at BEFORE UPDATE ON public.care_observations FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: care_shifts tg_care_shifts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_care_shifts_updated_at BEFORE UPDATE ON public.care_shifts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: care_tasks tg_care_tasks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_care_tasks_updated_at BEFORE UPDATE ON public.care_tasks FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: caregiver_certifications tg_caregiver_certifications_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_caregiver_certifications_updated_at BEFORE UPDATE ON public.caregiver_certifications FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: caregiver_profiles tg_caregiver_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_caregiver_profiles_updated_at BEFORE UPDATE ON public.caregiver_profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: caregiver_reviews tg_caregiver_reviews_rating; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_caregiver_reviews_rating AFTER INSERT OR DELETE OR UPDATE ON public.caregiver_reviews FOR EACH ROW EXECUTE FUNCTION public.caregiver_reviews_refresh_rating();


--
-- Name: caregiver_reviews tg_caregiver_reviews_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_caregiver_reviews_updated_at BEFORE UPDATE ON public.caregiver_reviews FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: contact_requests tg_contact_requests_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_contact_requests_updated_at BEFORE UPDATE ON public.contact_requests FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: content_items tg_content_items_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_content_items_updated_at BEFORE UPDATE ON public.content_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: conversations tg_conversations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_conversations_updated_at BEFORE UPDATE ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: daily_checkins tg_daily_checkins_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_daily_checkins_updated_at BEFORE UPDATE ON public.daily_checkins FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: elder_devices tg_elder_devices_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_elder_devices_updated_at BEFORE UPDATE ON public.elder_devices FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: elder_feed_items tg_elder_feed_items_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_elder_feed_items_updated_at BEFORE UPDATE ON public.elder_feed_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: emergency_contacts tg_emergency_contacts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_emergency_contacts_updated_at BEFORE UPDATE ON public.emergency_contacts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: files tg_files_purga_ocr; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_files_purga_ocr AFTER UPDATE OF purged_at ON public.files FOR EACH ROW WHEN (((old.purged_at IS NULL) AND (new.purged_at IS NOT NULL))) EXECUTE FUNCTION public.fn_purga_texto_ocr();


--
-- Name: files tg_files_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_files_updated_at BEFORE UPDATE ON public.files FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: gallery_photos tg_gallery_photos_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_gallery_photos_updated_at BEFORE UPDATE ON public.gallery_photos FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: incidents tg_incidents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_incidents_updated_at BEFORE UPDATE ON public.incidents FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: invitations tg_invitations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_invitations_updated_at BEFORE UPDATE ON public.invitations FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: job_offers tg_job_offers_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_job_offers_updated_at BEFORE UPDATE ON public.job_offers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: market_products tg_market_products_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_market_products_updated_at BEFORE UPDATE ON public.market_products FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: medical_documents tg_medical_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_medical_documents_updated_at BEFORE UPDATE ON public.medical_documents FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: medications tg_medications_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_medications_updated_at BEFORE UPDATE ON public.medications FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: messages tg_messages_notify; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_messages_notify AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.notify_new_message();


--
-- Name: music_creations tg_music_creations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_music_creations_updated_at BEFORE UPDATE ON public.music_creations FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: notification_settings tg_notification_settings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_notification_settings_updated_at BEFORE UPDATE ON public.notification_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: patient_immunizations tg_patient_immunizations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_patient_immunizations_updated_at BEFORE UPDATE ON public.patient_immunizations FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: patient_members tg_patient_members_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_patient_members_updated_at BEFORE UPDATE ON public.patient_members FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: patients tg_patients_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_patients_updated_at BEFORE UPDATE ON public.patients FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: plan_limits tg_plan_limits_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_plan_limits_updated_at BEFORE UPDATE ON public.plan_limits FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: plans tg_plans_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_plans_updated_at BEFORE UPDATE ON public.plans FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: push_devices tg_push_devices_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_push_devices_updated_at BEFORE UPDATE ON public.push_devices FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: scheduled_doses tg_scheduled_doses_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_scheduled_doses_updated_at BEFORE UPDATE ON public.scheduled_doses FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: shift_notes tg_shift_notes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_shift_notes_updated_at BEFORE UPDATE ON public.shift_notes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: subscriptions tg_subscriptions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_subscriptions_updated_at BEFORE UPDATE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: support_articles tg_support_articles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_support_articles_updated_at BEFORE UPDATE ON public.support_articles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: system_parameters tg_system_parameters_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_system_parameters_updated_at BEFORE UPDATE ON public.system_parameters FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: treatments tg_treatments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_treatments_updated_at BEFORE UPDATE ON public.treatments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: usage_counters tg_usage_counters_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_usage_counters_updated_at BEFORE UPDATE ON public.usage_counters FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: users tg_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: vital_thresholds tg_vital_thresholds_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_vital_thresholds_updated_at BEFORE UPDATE ON public.vital_thresholds FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: wearables tg_wearables_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_wearables_updated_at BEFORE UPDATE ON public.wearables FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: assistant_citations assistant_citations_query_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_citations
    ADD CONSTRAINT assistant_citations_query_id_fkey FOREIGN KEY (query_id) REFERENCES public.assistant_queries(id) ON DELETE RESTRICT;


--
-- Name: assistant_queries assistant_queries_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_queries
    ADD CONSTRAINT assistant_queries_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: care_tasks care_tasks_assigned_to_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_tasks
    ADD CONSTRAINT care_tasks_assigned_to_user_id_fkey FOREIGN KEY (assigned_to_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: care_tasks care_tasks_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_tasks
    ADD CONSTRAINT care_tasks_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: care_tasks care_tasks_patient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_tasks
    ADD CONSTRAINT care_tasks_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: chat_ws_sessions chat_ws_sessions_patient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_ws_sessions
    ADD CONSTRAINT chat_ws_sessions_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE;


--
-- Name: chat_ws_sessions chat_ws_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_ws_sessions
    ADD CONSTRAINT chat_ws_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: content_playbacks content_playbacks_content_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_playbacks
    ADD CONSTRAINT content_playbacks_content_item_id_fkey FOREIGN KEY (content_item_id) REFERENCES public.content_items(id) ON DELETE RESTRICT;


--
-- Name: content_playbacks content_playbacks_patient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_playbacks
    ADD CONSTRAINT content_playbacks_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: content_playbacks content_playbacks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_playbacks
    ADD CONSTRAINT content_playbacks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: conversations conversations_patient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: conversations conversations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: creation_shares creation_shares_music_creation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creation_shares
    ADD CONSTRAINT creation_shares_music_creation_id_fkey FOREIGN KEY (music_creation_id) REFERENCES public.music_creations(id) ON DELETE RESTRICT;


--
-- Name: creation_shares creation_shares_shared_with_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creation_shares
    ADD CONSTRAINT creation_shares_shared_with_user_id_fkey FOREIGN KEY (shared_with_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: activity_reports fk_activity_reports_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_reports
    ADD CONSTRAINT fk_activity_reports_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: activity_reports fk_activity_reports_requested_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_reports
    ADD CONSTRAINT fk_activity_reports_requested_by FOREIGN KEY (requested_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: activity_sessions fk_activity_sessions_device; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_sessions
    ADD CONSTRAINT fk_activity_sessions_device FOREIGN KEY (elder_device_id) REFERENCES public.elder_devices(id) ON DELETE RESTRICT;


--
-- Name: activity_sessions fk_activity_sessions_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_sessions
    ADD CONSTRAINT fk_activity_sessions_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: admin_audit_log fk_admin_audit_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_audit_log
    ADD CONSTRAINT fk_admin_audit_actor FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: admin_audit_log fk_admin_audit_target; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_audit_log
    ADD CONSTRAINT fk_admin_audit_target FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: alert_deliveries fk_alert_deliveries_alert; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_deliveries
    ADD CONSTRAINT fk_alert_deliveries_alert FOREIGN KEY (alert_id) REFERENCES public.alerts(id) ON DELETE RESTRICT;


--
-- Name: alert_deliveries fk_alert_deliveries_device; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_deliveries
    ADD CONSTRAINT fk_alert_deliveries_device FOREIGN KEY (push_device_id) REFERENCES public.push_devices(id) ON DELETE RESTRICT;


--
-- Name: alert_deliveries fk_alert_deliveries_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_deliveries
    ADD CONSTRAINT fk_alert_deliveries_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: alerts fk_alerts_acknowledged_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_alerts_acknowledged_by FOREIGN KEY (acknowledged_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: alerts fk_alerts_dose; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_alerts_dose FOREIGN KEY (dose_id) REFERENCES public.scheduled_doses(id) ON DELETE RESTRICT;


--
-- Name: alerts fk_alerts_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_alerts_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: alerts fk_alerts_resolved_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_alerts_resolved_by FOREIGN KEY (resolved_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: analytics_events fk_analytics_events_actor_device; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.analytics_events
    ADD CONSTRAINT fk_analytics_events_actor_device FOREIGN KEY (actor_device_id) REFERENCES public.elder_devices(id) ON DELETE RESTRICT;


--
-- Name: analytics_events fk_analytics_events_actor_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.analytics_events
    ADD CONSTRAINT fk_analytics_events_actor_user FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: analytics_events fk_analytics_events_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.analytics_events
    ADD CONSTRAINT fk_analytics_events_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: assistant_queries fk_assistant_queries_conversation; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_queries
    ADD CONSTRAINT fk_assistant_queries_conversation FOREIGN KEY (conversation_id, conversation_type) REFERENCES public.conversations(id, type) ON DELETE RESTRICT;


--
-- Name: audit_log fk_audit_log_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT fk_audit_log_actor FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: audit_log fk_audit_log_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT fk_audit_log_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: billing_events fk_billing_events_plan_price; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT fk_billing_events_plan_price FOREIGN KEY (plan_price_id) REFERENCES public.plan_prices(id) ON DELETE RESTRICT;


--
-- Name: billing_events fk_billing_events_subscription; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT fk_billing_events_subscription FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE RESTRICT;


--
-- Name: care_observations fk_care_observations_author; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_observations
    ADD CONSTRAINT fk_care_observations_author FOREIGN KEY (author_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: care_observations fk_care_observations_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_observations
    ADD CONSTRAINT fk_care_observations_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: care_observations fk_care_observations_photo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_observations
    ADD CONSTRAINT fk_care_observations_photo FOREIGN KEY (photo_file_id, patient_id) REFERENCES public.files(id, patient_id) ON DELETE RESTRICT;


--
-- Name: care_shifts fk_care_shifts_caregiver; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_shifts
    ADD CONSTRAINT fk_care_shifts_caregiver FOREIGN KEY (caregiver_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: care_shifts fk_care_shifts_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.care_shifts
    ADD CONSTRAINT fk_care_shifts_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: caregiver_certifications fk_caregiver_certifications_file; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_certifications
    ADD CONSTRAINT fk_caregiver_certifications_file FOREIGN KEY (file_id, file_scope) REFERENCES public.files(id, scope) ON DELETE RESTRICT;


--
-- Name: caregiver_certifications fk_caregiver_certifications_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_certifications
    ADD CONSTRAINT fk_caregiver_certifications_profile FOREIGN KEY (profile_id) REFERENCES public.caregiver_profiles(id) ON DELETE RESTRICT;


--
-- Name: caregiver_certifications fk_caregiver_certifications_verified_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_certifications
    ADD CONSTRAINT fk_caregiver_certifications_verified_by FOREIGN KEY (verified_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: caregiver_languages fk_caregiver_languages_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_languages
    ADD CONSTRAINT fk_caregiver_languages_profile FOREIGN KEY (profile_id) REFERENCES public.caregiver_profiles(id) ON DELETE RESTRICT;


--
-- Name: caregiver_profiles fk_caregiver_profiles_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_profiles
    ADD CONSTRAINT fk_caregiver_profiles_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: caregiver_reviews fk_caregiver_reviews_autor_del_circulo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_reviews
    ADD CONSTRAINT fk_caregiver_reviews_autor_del_circulo FOREIGN KEY (patient_id, author_id) REFERENCES public.patient_members(patient_id, user_id) ON DELETE RESTRICT;


--
-- Name: caregiver_reviews fk_caregiver_reviews_cuidadora_del_circulo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_reviews
    ADD CONSTRAINT fk_caregiver_reviews_cuidadora_del_circulo FOREIGN KEY (patient_id, reviewed_user_id) REFERENCES public.patient_members(patient_id, user_id) ON DELETE RESTRICT;


--
-- Name: caregiver_reviews fk_caregiver_reviews_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_reviews
    ADD CONSTRAINT fk_caregiver_reviews_profile FOREIGN KEY (profile_id, reviewed_user_id) REFERENCES public.caregiver_profiles(id, user_id) ON DELETE RESTRICT;


--
-- Name: caregiver_specialties fk_caregiver_specialties_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_specialties
    ADD CONSTRAINT fk_caregiver_specialties_profile FOREIGN KEY (profile_id) REFERENCES public.caregiver_profiles(id) ON DELETE RESTRICT;


--
-- Name: caregiver_specialties fk_caregiver_specialties_specialty; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_specialties
    ADD CONSTRAINT fk_caregiver_specialties_specialty FOREIGN KEY (specialty_code) REFERENCES public.specialties(code) ON DELETE RESTRICT;


--
-- Name: caregiver_zones fk_caregiver_zones_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caregiver_zones
    ADD CONSTRAINT fk_caregiver_zones_profile FOREIGN KEY (profile_id) REFERENCES public.caregiver_profiles(id) ON DELETE RESTRICT;


--
-- Name: contact_requests fk_contact_requests_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_requests
    ADD CONSTRAINT fk_contact_requests_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: contact_requests fk_contact_requests_profile; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_requests
    ADD CONSTRAINT fk_contact_requests_profile FOREIGN KEY (profile_id) REFERENCES public.caregiver_profiles(id) ON DELETE RESTRICT;


--
-- Name: contact_requests fk_contact_requests_requester; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_requests
    ADD CONSTRAINT fk_contact_requests_requester FOREIGN KEY (requester_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: content_items fk_content_items_file; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_items
    ADD CONSTRAINT fk_content_items_file FOREIGN KEY (file_id, file_scope) REFERENCES public.files(id, scope) ON DELETE RESTRICT;


--
-- Name: creation_shares fk_creation_shares_shared_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creation_shares
    ADD CONSTRAINT fk_creation_shares_shared_by FOREIGN KEY (shared_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: daily_checkins fk_daily_checkins_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_checkins
    ADD CONSTRAINT fk_daily_checkins_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: daily_checkins fk_daily_checkins_voice; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_checkins
    ADD CONSTRAINT fk_daily_checkins_voice FOREIGN KEY (voice_file_id, patient_id) REFERENCES public.files(id, patient_id) ON DELETE RESTRICT;


--
-- Name: device_link_codes fk_device_link_codes_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_link_codes
    ADD CONSTRAINT fk_device_link_codes_created_by FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: device_link_codes fk_device_link_codes_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_link_codes
    ADD CONSTRAINT fk_device_link_codes_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: doctor_enrollments fk_doctor_enrollments_accepted_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doctor_enrollments
    ADD CONSTRAINT fk_doctor_enrollments_accepted_by FOREIGN KEY (accepted_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: doctor_enrollments fk_doctor_enrollments_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doctor_enrollments
    ADD CONSTRAINT fk_doctor_enrollments_created_by FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: doctor_profiles fk_doctor_profiles_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doctor_profiles
    ADD CONSTRAINT fk_doctor_profiles_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: doctor_profiles fk_doctor_profiles_verified_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doctor_profiles
    ADD CONSTRAINT fk_doctor_profiles_verified_by FOREIGN KEY (verified_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: drug_catalog fk_drug_catalog_rule; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drug_catalog
    ADD CONSTRAINT fk_drug_catalog_rule FOREIGN KEY (form, route, unit) REFERENCES public.form_route_unit_rules(form, route, unit) ON DELETE RESTRICT;


--
-- Name: elder_devices fk_elder_devices_link_code; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT fk_elder_devices_link_code FOREIGN KEY (link_code_id) REFERENCES public.device_link_codes(id) ON DELETE RESTRICT;


--
-- Name: elder_devices fk_elder_devices_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT fk_elder_devices_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: elder_devices fk_elder_devices_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_devices
    ADD CONSTRAINT fk_elder_devices_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: elder_feed_items fk_elder_feed_items_image; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.elder_feed_items
    ADD CONSTRAINT fk_elder_feed_items_image FOREIGN KEY (image_file_id, image_scope) REFERENCES public.files(id, scope) ON DELETE RESTRICT;


--
-- Name: emergency_contacts fk_emergency_contacts_member; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emergency_contacts
    ADD CONSTRAINT fk_emergency_contacts_member FOREIGN KEY (member_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: emergency_contacts fk_emergency_contacts_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emergency_contacts
    ADD CONSTRAINT fk_emergency_contacts_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: file_ocr fk_file_ocr_file; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_ocr
    ADD CONSTRAINT fk_file_ocr_file FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE RESTRICT;


--
-- Name: files fk_files_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT fk_files_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: files fk_files_uploaded_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT fk_files_uploaded_by FOREIGN KEY (uploaded_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: incidents fk_incidents_alert; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT fk_incidents_alert FOREIGN KEY (alert_id, patient_id) REFERENCES public.alerts(id, patient_id) ON DELETE RESTRICT;


--
-- Name: incidents fk_incidents_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT fk_incidents_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: incidents fk_incidents_photo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT fk_incidents_photo FOREIGN KEY (photo_file_id, patient_id) REFERENCES public.files(id, patient_id) ON DELETE RESTRICT;


--
-- Name: incidents fk_incidents_reported_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT fk_incidents_reported_by FOREIGN KEY (reported_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: invitations fk_invitations_accepted_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT fk_invitations_accepted_by FOREIGN KEY (accepted_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: invitations fk_invitations_invited_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT fk_invitations_invited_by FOREIGN KEY (invited_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: invitations fk_invitations_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT fk_invitations_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: job_offers fk_job_offers_posted_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_offers
    ADD CONSTRAINT fk_job_offers_posted_by FOREIGN KEY (posted_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: market_products fk_market_products_image; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.market_products
    ADD CONSTRAINT fk_market_products_image FOREIGN KEY (image_file_id, image_scope) REFERENCES public.files(id, scope) ON DELETE RESTRICT;


--
-- Name: medical_documents fk_medical_documents_added_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_documents
    ADD CONSTRAINT fk_medical_documents_added_by FOREIGN KEY (added_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: medical_documents fk_medical_documents_deleted_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_documents
    ADD CONSTRAINT fk_medical_documents_deleted_by FOREIGN KEY (deleted_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: medical_documents fk_medical_documents_file; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_documents
    ADD CONSTRAINT fk_medical_documents_file FOREIGN KEY (file_id, patient_id) REFERENCES public.files(id, patient_id) ON DELETE RESTRICT;


--
-- Name: medical_documents fk_medical_documents_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_documents
    ADD CONSTRAINT fk_medical_documents_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: medication_days fk_medication_days_medication; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medication_days
    ADD CONSTRAINT fk_medication_days_medication FOREIGN KEY (medication_id) REFERENCES public.medications(id) ON DELETE RESTRICT;


--
-- Name: medication_times fk_medication_times_medication; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medication_times
    ADD CONSTRAINT fk_medication_times_medication FOREIGN KEY (medication_id) REFERENCES public.medications(id) ON DELETE RESTRICT;


--
-- Name: medications fk_medications_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medications
    ADD CONSTRAINT fk_medications_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: medications fk_medications_prescriber; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medications
    ADD CONSTRAINT fk_medications_prescriber FOREIGN KEY (prescribed_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: notification_settings fk_notification_settings_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT fk_notification_settings_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: patient_allergies fk_patient_allergies_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_allergies
    ADD CONSTRAINT fk_patient_allergies_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: patient_allergies fk_patient_allergies_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_allergies
    ADD CONSTRAINT fk_patient_allergies_user FOREIGN KEY (recorded_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: patient_conditions fk_patient_conditions_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_conditions
    ADD CONSTRAINT fk_patient_conditions_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: patient_immunizations fk_patient_immunizations_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_immunizations
    ADD CONSTRAINT fk_patient_immunizations_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: patient_immunizations fk_patient_immunizations_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_immunizations
    ADD CONSTRAINT fk_patient_immunizations_user FOREIGN KEY (recorded_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: patient_immunizations fk_patient_immunizations_vaccine; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_immunizations
    ADD CONSTRAINT fk_patient_immunizations_vaccine FOREIGN KEY (vaccine) REFERENCES public.vaccine_catalog(code) ON DELETE RESTRICT;


--
-- Name: patient_measurements fk_patient_measurements_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_measurements
    ADD CONSTRAINT fk_patient_measurements_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: patient_measurements fk_patient_measurements_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_measurements
    ADD CONSTRAINT fk_patient_measurements_user FOREIGN KEY (recorded_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: patient_members fk_patient_members_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_members
    ADD CONSTRAINT fk_patient_members_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: patient_members fk_patient_members_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.patient_members
    ADD CONSTRAINT fk_patient_members_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: plan_features fk_plan_features_feature; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_features
    ADD CONSTRAINT fk_plan_features_feature FOREIGN KEY (feature_code) REFERENCES public.features(code) ON DELETE RESTRICT;


--
-- Name: plan_features fk_plan_features_plan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_features
    ADD CONSTRAINT fk_plan_features_plan FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE RESTRICT;


--
-- Name: plan_limits fk_plan_limits_key; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_limits
    ADD CONSTRAINT fk_plan_limits_key FOREIGN KEY (limit_key) REFERENCES public.limit_keys(key) ON DELETE RESTRICT;


--
-- Name: plan_limits fk_plan_limits_plan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_limits
    ADD CONSTRAINT fk_plan_limits_plan FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE RESTRICT;


--
-- Name: plan_prices fk_plan_prices_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_prices
    ADD CONSTRAINT fk_plan_prices_created_by FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: plan_prices fk_plan_prices_plan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_prices
    ADD CONSTRAINT fk_plan_prices_plan FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE RESTRICT;


--
-- Name: plans fk_plans_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT fk_plans_created_by FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: treatment_item_prn_uses fk_prn_uses_item; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_prn_uses
    ADD CONSTRAINT fk_prn_uses_item FOREIGN KEY (treatment_item_id) REFERENCES public.treatment_items(id) ON DELETE RESTRICT;


--
-- Name: treatment_item_prn_uses fk_prn_uses_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_prn_uses
    ADD CONSTRAINT fk_prn_uses_user FOREIGN KEY (logged_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: push_devices fk_push_devices_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_devices
    ADD CONSTRAINT fk_push_devices_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: record_access_log fk_record_access_log_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.record_access_log
    ADD CONSTRAINT fk_record_access_log_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: record_access_log fk_record_access_log_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.record_access_log
    ADD CONSTRAINT fk_record_access_log_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: refresh_tokens fk_refresh_tokens_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT fk_refresh_tokens_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: scheduled_doses fk_scheduled_doses_medication; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_doses
    ADD CONSTRAINT fk_scheduled_doses_medication FOREIGN KEY (medication_id) REFERENCES public.medications(id) ON DELETE RESTRICT;


--
-- Name: scheduled_doses fk_scheduled_doses_treatment_item; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_doses
    ADD CONSTRAINT fk_scheduled_doses_treatment_item FOREIGN KEY (treatment_item_id) REFERENCES public.treatment_items(id) ON DELETE RESTRICT;


--
-- Name: scheduled_doses fk_scheduled_doses_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_doses
    ADD CONSTRAINT fk_scheduled_doses_user FOREIGN KEY (logged_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: shift_notes fk_shift_notes_acknowledged_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_notes
    ADD CONSTRAINT fk_shift_notes_acknowledged_by FOREIGN KEY (acknowledged_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: shift_notes fk_shift_notes_author; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_notes
    ADD CONSTRAINT fk_shift_notes_author FOREIGN KEY (author_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: shift_notes fk_shift_notes_handover_to; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_notes
    ADD CONSTRAINT fk_shift_notes_handover_to FOREIGN KEY (handover_to) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: shift_notes fk_shift_notes_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_notes
    ADD CONSTRAINT fk_shift_notes_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: sos_events fk_sos_events_alert; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sos_events
    ADD CONSTRAINT fk_sos_events_alert FOREIGN KEY (alert_id, patient_id) REFERENCES public.alerts(id, patient_id) ON DELETE RESTRICT;


--
-- Name: sos_events fk_sos_events_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sos_events
    ADD CONSTRAINT fk_sos_events_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: sos_events fk_sos_events_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sos_events
    ADD CONSTRAINT fk_sos_events_user FOREIGN KEY (triggered_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: subscriptions fk_subscriptions_granted_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT fk_subscriptions_granted_by FOREIGN KEY (granted_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: subscriptions fk_subscriptions_plan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT fk_subscriptions_plan FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE RESTRICT;


--
-- Name: subscriptions fk_subscriptions_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT fk_subscriptions_user FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: support_articles fk_support_articles_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_articles
    ADD CONSTRAINT fk_support_articles_created_by FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: system_parameters fk_system_parameters_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_parameters
    ADD CONSTRAINT fk_system_parameters_user FOREIGN KEY (updated_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: treatment_documents fk_treatment_documents_document; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_documents
    ADD CONSTRAINT fk_treatment_documents_document FOREIGN KEY (document_id) REFERENCES public.medical_documents(id) ON DELETE RESTRICT;


--
-- Name: treatment_documents fk_treatment_documents_treatment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_documents
    ADD CONSTRAINT fk_treatment_documents_treatment FOREIGN KEY (treatment_id) REFERENCES public.treatments(id) ON DELETE RESTRICT;


--
-- Name: treatment_item_days fk_treatment_item_days_item; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_days
    ADD CONSTRAINT fk_treatment_item_days_item FOREIGN KEY (treatment_item_id) REFERENCES public.treatment_items(id) ON DELETE RESTRICT;


--
-- Name: treatment_item_times fk_treatment_item_times_item; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_item_times
    ADD CONSTRAINT fk_treatment_item_times_item FOREIGN KEY (treatment_item_id) REFERENCES public.treatment_items(id) ON DELETE RESTRICT;


--
-- Name: treatment_items fk_treatment_items_continues; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_items
    ADD CONSTRAINT fk_treatment_items_continues FOREIGN KEY (continues_item_id) REFERENCES public.treatment_items(id) ON DELETE RESTRICT;


--
-- Name: treatment_items fk_treatment_items_drug; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_items
    ADD CONSTRAINT fk_treatment_items_drug FOREIGN KEY (drug_code) REFERENCES public.drug_catalog(code) ON DELETE RESTRICT;


--
-- Name: treatment_items fk_treatment_items_treatment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatment_items
    ADD CONSTRAINT fk_treatment_items_treatment FOREIGN KEY (treatment_id) REFERENCES public.treatments(id) ON DELETE RESTRICT;


--
-- Name: treatments fk_treatments_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatments
    ADD CONSTRAINT fk_treatments_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: treatments fk_treatments_prescriber; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatments
    ADD CONSTRAINT fk_treatments_prescriber FOREIGN KEY (prescribed_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: treatments fk_treatments_supersedes; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.treatments
    ADD CONSTRAINT fk_treatments_supersedes FOREIGN KEY (supersedes_id) REFERENCES public.treatments(id) ON DELETE RESTRICT;


--
-- Name: usage_counters fk_usage_counters_subscription; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_counters
    ADD CONSTRAINT fk_usage_counters_subscription FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE RESTRICT;


--
-- Name: users fk_users_deactivated_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_users_deactivated_by FOREIGN KEY (deactivated_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: vital_readings fk_vital_readings_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.vital_readings
    ADD CONSTRAINT fk_vital_readings_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: vital_readings fk_vital_readings_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.vital_readings
    ADD CONSTRAINT fk_vital_readings_type FOREIGN KEY (type) REFERENCES public.vital_types(code) ON DELETE RESTRICT;


--
-- Name: vital_thresholds fk_vital_thresholds_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_thresholds
    ADD CONSTRAINT fk_vital_thresholds_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: vital_thresholds fk_vital_thresholds_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_thresholds
    ADD CONSTRAINT fk_vital_thresholds_type FOREIGN KEY (type) REFERENCES public.vital_types(code) ON DELETE RESTRICT;


--
-- Name: vital_thresholds fk_vital_thresholds_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vital_thresholds
    ADD CONSTRAINT fk_vital_thresholds_user FOREIGN KEY (updated_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: wearables fk_wearables_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wearables
    ADD CONSTRAINT fk_wearables_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: wellbeing_snapshots fk_wellbeing_snapshots_patient; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wellbeing_snapshots
    ADD CONSTRAINT fk_wellbeing_snapshots_patient FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: gallery_photos gallery_photos_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gallery_photos
    ADD CONSTRAINT gallery_photos_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE RESTRICT;


--
-- Name: gallery_photos gallery_photos_patient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gallery_photos
    ADD CONSTRAINT gallery_photos_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: gallery_photos gallery_photos_published_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gallery_photos
    ADD CONSTRAINT gallery_photos_published_by_user_id_fkey FOREIGN KEY (published_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: idempotency_keys idempotency_keys_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT idempotency_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: message_receipts message_receipts_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_receipts
    ADD CONSTRAINT message_receipts_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE RESTRICT;


--
-- Name: message_receipts message_receipts_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_receipts
    ADD CONSTRAINT message_receipts_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE RESTRICT;


--
-- Name: messages messages_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE RESTRICT;


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: music_creations music_creations_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.music_creations
    ADD CONSTRAINT music_creations_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: music_creations music_creations_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.music_creations
    ADD CONSTRAINT music_creations_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE RESTRICT;


--
-- Name: music_creations music_creations_patient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.music_creations
    ADD CONSTRAINT music_creations_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT;


--
-- Name: password_reset_tokens password_reset_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: photo_reactions photo_reactions_photo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.photo_reactions
    ADD CONSTRAINT photo_reactions_photo_id_fkey FOREIGN KEY (photo_id) REFERENCES public.gallery_photos(id) ON DELETE RESTRICT;


--
-- Name: photo_reactions photo_reactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.photo_reactions
    ADD CONSTRAINT photo_reactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--



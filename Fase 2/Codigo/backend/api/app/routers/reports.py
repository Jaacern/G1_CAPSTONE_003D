"""Reportes clínicos en PDF (Fase 6).

Caso de uso principal: la hoja de emergencia. Cuando al paciente le pasa algo y
llega un paramédico / doctor de turno que no lo conoce, necesita en segundos:
identidad, patologías, ALERGIAS, tratamientos vigentes con dosis, contactos de
emergencia, previsión y los últimos signos vitales. Un PDF resuelve esto aunque
el receptor no tenga acceso a la app.

Decisiones (docs/DECISIONES_ABIERTAS_FICHA.md, punto 6):
  · El PDF se genera en el BACKEND (ReportLab, Python puro) → mismo resultado en
    web y móvil, compartible, formato centralizado.
  · Se parte por: hoja de emergencia + signos vitales alrededor de un incidente.
  · Pie con fecha/hora de emisión y "generado por AgeCare": es una instantánea.
  · Solo para miembros del paciente (misma autorización que el resto).
"""
from datetime import datetime, timedelta, timezone
from io import BytesIO

from fastapi import APIRouter, Depends, Query
from fastapi.responses import StreamingResponse
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import PatientContext, get_patient_member
from app.errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["reports"])


# --------------------------------------------------------------------------
# Recolección de datos (SQL directo; no acopla a los otros routers)
# --------------------------------------------------------------------------
async def _datos_paciente(db: AsyncSession, patient_id: str) -> dict:
    row = (
        await db.execute(
            text(
                """
                SELECT full_name, birth_date, sex, rut_number, rut_dv,
                       address, marital_status, insurance, rcv_level, complexity
                FROM patients
                WHERE id = :pid AND deleted_at IS NULL
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()
    if row is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")
    rut = None
    if row["rut_number"] is not None:
        n = f"{row['rut_number']:,}".replace(",", ".")
        rut = f"{n}-{row['rut_dv']}" if row["rut_dv"] else n
    hoy = datetime.now().date()
    bd = row["birth_date"]
    edad = hoy.year - bd.year - ((hoy.month, hoy.day) < (bd.month, bd.day))
    return {
        "full_name": row["full_name"],
        "edad": edad,
        "sex": row["sex"],
        "rut": rut,
        "address": row["address"],
        "insurance": row["insurance"],
        "rcv_level": row["rcv_level"],
        "complexity": row["complexity"],
    }


async def _patologias(db: AsyncSession, patient_id: str) -> list[str]:
    rows = (
        await db.execute(
            text(
                """
                SELECT COALESCE(cc.label, pc.condition) AS label
                FROM patient_conditions pc
                LEFT JOIN condition_catalog cc ON cc.code = pc.condition
                WHERE pc.patient_id = :pid AND pc.deleted_at IS NULL
                ORDER BY label
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [r["label"] for r in rows]


async def _alergias(db: AsyncSession, patient_id: str) -> list[dict]:
    rows = (
        await db.execute(
            text(
                """
                SELECT COALESCE(ac.label, pa.substance) AS label,
                       pa.severity, pa.reaction, pa.category
                FROM patient_allergies pa
                LEFT JOIN allergen_catalog ac ON ac.code = pa.substance
                WHERE pa.patient_id = :pid AND pa.deleted_at IS NULL
                ORDER BY CASE pa.severity
                    WHEN 'anafilaxia' THEN 0 WHEN 'severa' THEN 1
                    WHEN 'moderada' THEN 2 ELSE 3 END, label
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [dict(r) for r in rows]


async def _tratamientos_vigentes(db: AsyncSession, patient_id: str) -> list[dict]:
    """Indicaciones vigentes de todas las especialidades (lo que el paciente
    toma hoy), con su dosis, horarios y quien las indico.

    El que indico va por tratamiento y no por paciente: cada especialidad
    tiene su medico, y en urgencias hay que saber a quien llamar por cada
    farmaco."""
    rows = (
        await db.execute(
            text(
                """
                SELECT t.specialty, ti.name, ti.dose_text, ti.is_prn,
                       ti.schedule_label, t.prescriber_role,
                       NULLIF(trim(concat_ws(' ', u.first_name, u.last_name)), '')
                         AS prescriber_name,
                       COALESCE(
                         (SELECT string_agg(to_char(tt.time_of_day, 'HH24:MI'), ', '
                                            ORDER BY tt.time_of_day)
                          FROM treatment_item_times tt
                          WHERE tt.treatment_item_id = ti.id), '') AS horarios
                FROM treatments t
                JOIN treatment_items ti ON ti.treatment_id = t.id
                LEFT JOIN users u ON u.id = t.prescribed_by
                WHERE t.patient_id = :pid AND t.status = 'vigente'
                  AND ti.action <> 'removed'
                ORDER BY t.specialty, ti.is_prn, ti.name
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [dict(r) for r in rows]


async def _contactos_emergencia(db: AsyncSession, patient_id: str) -> list[dict]:
    """Contactos de emergencia ACTIVOS, en orden. Nombre/teléfono del miembro
    del grupo si aplica (una sola fuente); si es contacto libre, los propios."""
    rows = (
        await db.execute(
            text(
                """
                SELECT COALESCE(u.full_name, ec.full_name) AS nombre,
                       COALESCE(u.phone, ec.phone)          AS telefono
                FROM emergency_contacts ec
                LEFT JOIN users u ON u.id = ec.member_user_id
                WHERE ec.patient_id = :pid AND ec.deleted_at IS NULL
                  AND ec.is_active = true
                ORDER BY nombre
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [dict(r) for r in rows]


async def _ultimos_vitales(db: AsyncSession, patient_id: str) -> list[dict]:
    """Última lectura por tipo (el estado más reciente del paciente)."""
    rows = (
        await db.execute(
            text(
                """
                SELECT DISTINCT ON (vr.type)
                       vr.type, vr.value, vr.value_secondary, vr.measured_at,
                       vt.label, vt.unit
                FROM vital_readings vr
                LEFT JOIN vital_types vt ON vt.code = vr.type
                WHERE vr.patient_id = :pid
                ORDER BY vr.type, vr.measured_at DESC
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [dict(r) for r in rows]


async def _vitales_ventana(db: AsyncSession, patient_id: str,
                           centro: datetime, horas: int) -> list[dict]:
    """Lecturas en una ventana de ±[horas] alrededor de un instante (incidente).
    Sirve para mostrar 'cómo estaba antes y después'."""
    desde = centro - timedelta(hours=horas)
    hasta = centro + timedelta(hours=horas)
    rows = (
        await db.execute(
            text(
                """
                SELECT vr.type, vr.value, vr.value_secondary, vr.measured_at,
                       vt.label, vt.unit
                FROM vital_readings vr
                LEFT JOIN vital_types vt ON vt.code = vr.type
                WHERE vr.patient_id = :pid
                  AND vr.measured_at >= :desde AND vr.measured_at <= :hasta
                ORDER BY vr.measured_at ASC, vr.type
                """
            ),
            {"pid": patient_id, "desde": desde, "hasta": hasta},
        )
    ).mappings().all()
    return [dict(r) for r in rows]


# --------------------------------------------------------------------------
# Armado del PDF (ReportLab)
# --------------------------------------------------------------------------
_SEX_LABEL = {"female": "Femenino", "male": "Masculino", "other": "Otro"}
_SEV_LABEL = {"leve": "Leve", "moderada": "Moderada",
              "severa": "SEVERA", "anafilaxia": "ANAFILAXIA"}
_INSUR_LABEL = {"fonasa": "Fonasa", "isapre": "Isapre",
                "particular": "Particular", "otra": "Otra"}
_SPEC_LABEL = {
    "general": "Medicina general", "cardiologia": "Cardiología",
    "traumatologia": "Traumatología", "neurologia": "Neurología",
    "geriatria": "Geriatría", "endocrinologia": "Endocrinología",
    "psiquiatria": "Psiquiatría", "nefrologia": "Nefrología",
    "broncopulmonar": "Broncopulmonar",
}


def _fmt_dt(dt: datetime) -> str:
    return dt.strftime("%d/%m/%Y %H:%M") if dt else ""


def _hoja_emergencia_pdf(datos: dict, patologias: list[str],
                         alergias: list[dict], tratamientos: list[dict],
                         contactos: list[dict], vitales: list[dict]) -> bytes:
    """Arma la hoja de emergencia (1-2 páginas) y devuelve los bytes del PDF.
    Lo crítico arriba: identidad, alergias (destacadas), tratamientos."""
    # Import local: ReportLab solo se carga cuando se genera un PDF.
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.platypus import (
        SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable)

    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        leftMargin=16 * mm, rightMargin=16 * mm,
        topMargin=14 * mm, bottomMargin=14 * mm,
        title="Hoja de emergencia", author="AgeCare",
    )
    ss = getSampleStyleSheet()
    rojo = colors.HexColor("#C0392B")
    azul = colors.HexColor("#2455B3")
    gris = colors.HexColor("#555555")

    h_title = ParagraphStyle("t", parent=ss["Title"], fontSize=18,
                             textColor=azul, spaceAfter=2)
    h_sec = ParagraphStyle("s", parent=ss["Heading2"], fontSize=12,
                           textColor=azul, spaceBefore=10, spaceAfter=4)
    h_sec_rojo = ParagraphStyle("sr", parent=h_sec, textColor=rojo)
    body = ParagraphStyle("b", parent=ss["BodyText"], fontSize=10, leading=14)
    small = ParagraphStyle("sm", parent=ss["BodyText"], fontSize=8,
                           textColor=gris)
    alerta = ParagraphStyle("al", parent=body, fontSize=11, textColor=rojo,
                            leading=15)

    el = []

    # ── Encabezado ──
    el.append(Paragraph("HOJA DE EMERGENCIA", h_title))
    el.append(Paragraph(
        "Resumen clínico para atención de urgencia · AgeCare", small))
    el.append(HRFlowable(width="100%", thickness=1.2, color=azul,
                         spaceBefore=4, spaceAfter=8))

    # ── Identidad ──
    sexo = _SEX_LABEL.get(datos["sex"], datos["sex"] or "—")
    prev = _INSUR_LABEL.get(datos["insurance"], datos["insurance"] or "—")
    ident = [
        ["Nombre", datos["full_name"]],
        ["Edad", f"{datos['edad']} años"],
        ["Sexo", sexo],
        ["RUT", datos["rut"] or "—"],
        ["Domicilio", datos["address"] or "—"],
        ["Previsión", prev],
    ]
    if datos.get("rcv_level"):
        ident.append(["Riesgo cardiovascular", datos["rcv_level"].capitalize()])
    if datos.get("complexity"):
        ident.append(["Complejidad", datos["complexity"].capitalize()])
    t_id = Table(ident, colWidths=[42 * mm, 120 * mm])
    t_id.setStyle(TableStyle([
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("TEXTCOLOR", (0, 0), (0, -1), gris),
        ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
    ]))
    el.append(t_id)

    # ── ALERGIAS (lo más crítico, en rojo) ──
    el.append(Paragraph("⚠ ALERGIAS", h_sec_rojo))
    if not alergias:
        el.append(Paragraph("Sin alergias registradas.", body))
    else:
        for a in alergias:
            sev = _SEV_LABEL.get(a["severity"], a["severity"])
            reac = f" — {a['reaction']}" if a.get("reaction") else ""
            el.append(Paragraph(f"• <b>{a['label']}</b> ({sev}){reac}", alerta))

    # ── Patologías ──
    el.append(Paragraph("Antecedentes mórbidos", h_sec))
    el.append(Paragraph(", ".join(patologias) if patologias
                        else "Sin patologías registradas.", body))

    # ── Tratamientos vigentes ──
    el.append(Paragraph("Tratamiento vigente", h_sec))
    if not tratamientos:
        el.append(Paragraph("Sin tratamiento vigente registrado.", body))
    else:
        filas = [["Especialidad / médico", "Fármaco", "Dosis", "Indicación"]]
        for it in tratamientos:
            if it["is_prn"]:
                ind = "SOS" + (f" ({it['schedule_label']})"
                              if it.get("schedule_label") else "")
            else:
                ind = it["horarios"] or "—"
                if it.get("schedule_label"):
                    ind += f" ({it['schedule_label']})"
            filas.append([
                _especialidad_y_medico(it),
                it["name"], it["dose_text"], ind,
            ])
        t_tr = Table(filas, colWidths=[34 * mm, 48 * mm, 26 * mm, 54 * mm])
        t_tr.setStyle(TableStyle([
            ("FONTSIZE", (0, 0), (-1, -1), 9),
            ("BACKGROUND", (0, 0), (-1, 0), azul),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1),
             [colors.white, colors.HexColor("#F2F5FB")]),
            ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#CCCCCC")),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ]))
        el.append(t_tr)

    # ── Últimos signos vitales ──
    el.append(Paragraph("Últimos signos vitales", h_sec))
    if not vitales:
        el.append(Paragraph("Sin lecturas registradas.", body))
    else:
        filas = [["Signo", "Valor", "Medido"]]
        for v in vitales:
            val = _fmt_valor(v)
            etiqueta = _ascii_seguro(v["label"] or v["type"])
            filas.append([etiqueta, val, _fmt_dt(v["measured_at"])])
        t_v = Table(filas, colWidths=[56 * mm, 46 * mm, 60 * mm])
        t_v.setStyle(TableStyle([
            ("FONTSIZE", (0, 0), (-1, -1), 9),
            ("BACKGROUND", (0, 0), (-1, 0), azul),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#CCCCCC")),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ]))
        el.append(t_v)

    # ── Contactos de emergencia ──
    el.append(Paragraph("Contactos de emergencia", h_sec))
    if not contactos:
        el.append(Paragraph("Sin contactos registrados.", body))
    else:
        for c in contactos:
            tel = c.get("telefono") or "—"
            el.append(Paragraph(f"• <b>{c['nombre']}</b> — {tel}", body))

    # ── Pie: instantánea, no dato en vivo ──
    el.append(Spacer(1, 10))
    el.append(HRFlowable(width="100%", thickness=0.6, color=gris))
    emision = datetime.now().strftime("%d/%m/%Y %H:%M")
    el.append(Paragraph(
        f"Generado por AgeCare el {emision}. Es una instantánea del expediente; "
        "los datos pueden haber cambiado. No reemplaza la evaluación clínica.",
        small))

    doc.build(el)
    buf.seek(0)
    return buf.read()


def _especialidad_y_medico(it: dict) -> str:
    """Celda 'Especialidad' con quien indico el tratamiento debajo.

    Si lo indico una cuidadora (prescriber_role='caregiver') se dice, para que
    nadie en urgencias lo lea como una indicacion medica."""
    esp = _SPEC_LABEL.get(it["specialty"], it["specialty"])
    nombre = it.get("prescriber_name") or "Sin registro"
    if it.get("prescriber_role") == "caregiver":
        nombre += " (cuidadora)"
    return f"{esp}\n{nombre}"


def _fmt_valor(v: dict) -> str:
    """Formatea un signo vital (presión lleva sistólica/diastólica)."""
    unidad = _ascii_seguro(v.get("unit") or "")
    if v["type"] == "blood_pressure" and v.get("value_secondary") is not None:
        return f"{_num(v['value'])}/{_num(v['value_secondary'])} {unidad}".strip()
    return f"{_num(v['value'])} {unidad}".strip()


def _ascii_seguro(s: str) -> str:
    """Reemplaza caracteres que las fuentes base de ReportLab (Helvetica) no
    dibujan, como el subíndice ₂ de 'Saturación O₂'. Mantiene los acentos, que
    sí están en latin-1; solo normaliza los subíndices Unicode comunes."""
    subs = {"₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
            "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9"}
    for k, val in subs.items():
        s = s.replace(k, val)
    return s


def _num(x) -> str:
    f = float(x)
    return str(int(f)) if f == int(f) else str(f)


# --------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/report")
async def patient_report(
    type: str = Query("emergency", description="emergency | vitals_incident"),
    incident_at: datetime | None = Query(
        None, description="Instante del incidente (para type=vitals_incident)"),
    window_hours: int = Query(1, ge=1, le=24,
                              description="Ventana ± horas alrededor del incidente"),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Genera un PDF del paciente. Solo miembros del paciente (autorización del
    dependency). type=emergency: hoja de emergencia. type=vitals_incident:
    signos vitales alrededor de un incidente."""
    datos = await _datos_paciente(db, ctx.patient_id)

    if type == "emergency":
        pdf = _hoja_emergencia_pdf(
            datos,
            await _patologias(db, ctx.patient_id),
            await _alergias(db, ctx.patient_id),
            await _tratamientos_vigentes(db, ctx.patient_id),
            await _contactos_emergencia(db, ctx.patient_id),
            await _ultimos_vitales(db, ctx.patient_id),
        )
        nombre = "hoja_emergencia.pdf"
    elif type == "vitals_incident":
        centro = incident_at or datetime.now(timezone.utc)
        pdf = _vitales_incidente_pdf(
            datos, centro, window_hours,
            await _vitales_ventana(db, ctx.patient_id, centro, window_hours),
        )
        nombre = "signos_incidente.pdf"
    else:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message=f"Tipo de reporte no válido: {type}.")

    return StreamingResponse(
        BytesIO(pdf), media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="{nombre}"'},
    )


def _vitales_incidente_pdf(datos: dict, centro: datetime, horas: int,
                           lecturas: list[dict]) -> bytes:
    """PDF de signos vitales alrededor de un incidente (antes/después)."""
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.platypus import (
        SimpleDocTemplate, Paragraph, Table, TableStyle, HRFlowable, Spacer)

    buf = BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, leftMargin=16 * mm,
                            rightMargin=16 * mm, topMargin=14 * mm,
                            bottomMargin=14 * mm,
                            title="Signos vitales", author="AgeCare")
    ss = getSampleStyleSheet()
    azul = colors.HexColor("#2455B3")
    gris = colors.HexColor("#555555")
    h_title = ParagraphStyle("t", parent=ss["Title"], fontSize=17,
                             textColor=azul)
    body = ParagraphStyle("b", parent=ss["BodyText"], fontSize=10, leading=14)
    small = ParagraphStyle("sm", parent=ss["BodyText"], fontSize=8,
                           textColor=gris)

    el = [Paragraph("SIGNOS VITALES — VENTANA DE INCIDENTE", h_title)]
    el.append(Paragraph(
        f"{datos['full_name']} · {datos['edad']} años", small))
    el.append(HRFlowable(width="100%", thickness=1.2, color=azul,
                         spaceBefore=4, spaceAfter=8))
    el.append(Paragraph(
        f"Incidente de referencia: <b>{_fmt_dt(centro)}</b>. "
        f"Ventana: ±{horas} h.", body))
    el.append(Spacer(1, 6))

    if not lecturas:
        el.append(Paragraph("Sin lecturas en la ventana indicada.", body))
    else:
        filas = [["Hora", "Signo", "Valor"]]
        for v in lecturas:
            filas.append([_fmt_dt(v["measured_at"]),
                          _ascii_seguro(v["label"] or v["type"]), _fmt_valor(v)])
        t = Table(filas, colWidths=[54 * mm, 56 * mm, 52 * mm])
        t.setStyle(TableStyle([
            ("FONTSIZE", (0, 0), (-1, -1), 9),
            ("BACKGROUND", (0, 0), (-1, 0), azul),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1),
             [colors.white, colors.HexColor("#F2F5FB")]),
            ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#CCCCCC")),
        ]))
        el.append(t)

    el.append(Spacer(1, 10))
    el.append(HRFlowable(width="100%", thickness=0.6, color=gris))
    el.append(Paragraph(
        f"Generado por AgeCare el {datetime.now().strftime('%d/%m/%Y %H:%M')}. "
        "Instantánea del expediente; no reemplaza la evaluación clínica.", small))

    doc.build(el)
    buf.seek(0)
    return buf.read()

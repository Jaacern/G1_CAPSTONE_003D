<div align="center">

# AgeCare
### Plataforma Digital de Cuidado de Adultos Mayores

**Proyecto de Título — Capstone**
**APT122 · PTY4614 · Grupo 1 · Sección 003D**
Ingeniería en Informática · Sede San Andrés · Duoc UC · 2026

</div>

---

> ## Aviso de Confidencialidad y Uso Académico
>
> Este repositorio tiene un propósito **exclusivamente académico**, en el marco de la asignatura **Capstone (APT122 · PTY4614)** de la carrera de Ingeniería en Informática de **Duoc UC**.
>
> El proyecto se desarrolla bajo un **acuerdo de confidencialidad**. En consecuencia, este repositorio contiene **únicamente los entregables académicos** del equipo, incluido el código desarrollado para la asignatura, y **no incluye** datos reales, credenciales ni información de negocio de la empresa contraparte.
>
> Todo dato personal sensible (por ejemplo, identificadores nacionales) ha sido removido de la documentación pública. No se autoriza el uso, la copia ni la distribución de este material con fines distintos al académico.

---

## Tabla de contenidos

1. [Descripción](#1-descripción)
2. [Contexto y motivación](#2-contexto-y-motivación)
3. [Alcance de este repositorio](#3-alcance-de-este-repositorio)
4. [Equipo de desarrollo](#4-equipo-de-desarrollo)
5. [Metodología](#5-metodología)
6. [Aseguramiento de calidad](#6-aseguramiento-de-calidad)
7. [Seguridad y protección de datos](#7-seguridad-y-protección-de-datos)
8. [Fase 1 — Evidencias](#8-fase-1--evidencias)
9. [Fase 2 — Evidencias](#9-fase-2--evidencias)
10. [Estructura del repositorio](#10-estructura-del-repositorio)
11. [Licencia y uso](#11-licencia-y-uso)

---

## 1. Descripción

**AgeCare** es una propuesta de plataforma digital orientada a apoyar el cuidado de adultos mayores y a mejorar la coordinación entre las personas involucradas en ese cuidado: familia, cuidadores, personal de salud y la propia persona mayor.

Este repositorio reúne la evidencia académica del equipo correspondiente a la **Fase 1 — Definición del Proyecto** y a la **Fase 2 — Diseño, desarrollo y cierre** (documentación técnica, modelo de datos relacional y código fuente).

---

## 2. Contexto y motivación

Chile atraviesa un proceso acelerado de envejecimiento poblacional, lo que incrementa la necesidad de herramientas que apoyen el cuidado de las personas mayores y faciliten la coordinación entre quienes las asisten. AgeCare aborda esta necesidad como **caso de estudio académico**, priorizando la accesibilidad, la seguridad de la información y la coordinación entre los distintos roles.

---

## 3. Alcance de este repositorio

**Incluye:**
- Evidencia grupal e individual de la Fase 1 (definición del proyecto).
- Avance de la Fase 2 (diseño): requerimientos funcionales, modelo relacional, diccionario de datos, normalización, análisis de realidad y decisiones, y esquema SQL.
- Cierre de la Fase 2: código fuente del backend, la base de datos, la aplicación móvil y web, el panel de administración y la aplicación de prueba del reloj, con sus pruebas automatizadas.
- Documentación académica de carácter general.

**No incluye (por confidencialidad):**
- Datos reales, credenciales, secretos o variables de entorno.
- Información de negocio o proyecciones.

---

## 4. Equipo de desarrollo

Redactado y mantenido por el equipo de ingeniería del proyecto:

| Integrante | Rol |
|-----------|-----|
| **Javier Cerna Chávez** | Tech Lead |
| **Benjamín Camus Jara** | Data Engineer |
| **Juan Pablo Mora Rosales** | Administrador de Base de Datos (DBA) |

Todos los integrantes son estudiantes de **Ingeniería en Informática** (Sede San Andrés · Duoc UC).
Asignatura: **PTY4614 Capstone** · Código **APT122** · Sección **003D**.

---

## 5. Metodología

El proyecto se organiza en **fases**, con revisión documental entre cada una. Cada fase entrega documentación formal antes de habilitar la siguiente, favoreciendo la trazabilidad y el control de cambios.

| Fase | Descripción | Estado |
|:----:|-------------|:------:|
| 1 | Definición del proyecto | Entrega formativa |
| 2 | Diseño | Avance entregado |
| 3 | Implementación (backend) | Entregada al cierre |
| 4 | Implementación (frontend) | Entregada al cierre |
| 5 | Pruebas y calidad | Entregada al cierre |
| 6 | Despliegue y cierre | Entregado, con despliegue de demostración |

---

## 6. Aseguramiento de calidad

Como práctica del equipo se aplican lineamientos de ingeniería de software: control de versiones, revisión entre pares, gestión formal de cambios y documentación versionada por entrega. Las pruebas automatizadas están en `Fase 2/Codigo/backend/api/tests` y `Fase 2/Codigo/frontend/test`, y se ejecutan con cada cambio mediante GitHub Actions (`.github/workflows`).

---

## 7. Seguridad y protección de datos

La seguridad se aborda desde el inicio del proyecto (*security by design*), bajo los siguientes principios:

- **Confidencialidad:** no se publican datos sensibles, secretos ni credenciales en este repositorio.
- **Mínimo privilegio:** el acceso a la información se otorga según el rol.
- **Cumplimiento normativo:** el tratamiento de datos personales se ajusta a la normativa chilena vigente en la materia.
- **Trazabilidad:** control de versiones y registro de cambios sobre la documentación.

El detalle de las medidas aplicadas está en `SECURITY.md` y en el README de `Fase 2/Codigo`. Las credenciales y los secretos **no forman parte de este repositorio**.

---

## 8. Fase 1 — Evidencias

- **Evidencias Grupales:** documentos de definición y evaluación del proyecto.
- **Evidencias Individuales:** autoevaluación de competencias, diario de reflexión y autoevaluación de cada integrante.

---

## 9. Fase 2 — Evidencias

La Fase 2 tiene dos entregas, y la carpeta `Fase 2/Evidencias Proyecto` conserva las dos.

- **Avance (4 de octubre).** Documenta el diseño de la base de datos tal como estaba en esa fecha: 24 tablas, normalizadas hasta 2FN.
- **Cierre.** Corresponde al sistema completo: 90 tablas normalizadas hasta 3FN, construidas con 131 migraciones versionadas, más el código fuente en `Fase 2/Codigo`.

Los documentos del avance no se reescribieron, para que sigan mostrando lo que se entregó en esa fecha. Por eso el modelo relacional, el diccionario de datos y los diagramas describen las 24 tablas del avance. El modelo final se consulta en `11_schema_al_cierre.sql` y en las migraciones de `Fase 2/Codigo/backend/sql`.

### Evidencias de Proyecto

| Documento | Entrega | Descripción |
|-----------|:-------:|-------------|
| `00_ERS_Simplificado_Fase1.docx` | Avance | Especificación de Requerimientos de Software (simplificada). |
| `01_Documento_Requerimientos_Funcionales.docx` | Avance | Requerimientos y qué soportaba el modelo de datos al 4 de octubre. |
| `02_Modelo_Relacional_Definitivo.docx` | Avance | Modelo relacional del avance (24 tablas). |
| `03_Diccionario_de_Datos.docx` | Avance | Diccionario de datos del avance (24 tablas). |
| `04_Normalizacion_2FN.docx` | Avance | Primera revisión de normalización, hasta 2FN. La reemplaza la revisión 3FN. |
| `04_Normalizacion_3FN.docx` | Cierre | Revisión de normalización hasta 3FN (versión 2, hecha sobre 65 tablas). |
| `05_Analisis_de_Realidad_y_Decisiones.docx` | Avance | Análisis de realidad y decisiones de diseño. |
| `07_schema_completo.sql` | Avance | Esquema SQL consolidado del avance (24 tablas). |
| `08_Diagrama V2.0.pdf` | Avance | Diagrama del modelo del avance. |
| `09_AgeCare_Diagrama_ER.png` | Avance | Diagrama entidad-relación del avance. |
| `10_Estado_de_Requisitos_al_Cierre.docx` | Cierre | Estado de los 107 requisitos del ERS al cierre, con la evidencia de cada uno. |
| `11_schema_al_cierre.sql` | Cierre | Esquema SQL final (90 tablas), generado a partir de las 131 migraciones. |

### Código fuente

El código del proyecto está en `Fase 2/Codigo`, con su propio README de instalación y ejecución.

| Carpeta | Contenido |
|---------|-----------|
| `backend/api` | API REST en FastAPI, servicios de fondo y pruebas automatizadas. |
| `backend/sql` | Migraciones numeradas de la base de datos y sus scripts de reversión. |
| `frontend` | Aplicación móvil y web en Flutter. |
| `admin_web` | Panel web de administración. |
| `watch_app` | Aplicación de prueba para reloj (Wear OS). |

### Otras evidencias de la Fase 2

- **Evidencias Grupales:** guía del estudiante de la fase y planilla de evaluación del avance.
- **Evidencias Individuales:** autoevaluación del avance de la Fase 2 de cada integrante (Benjamín Camus, Javier Cerna y Juan Mora).

---

## 10. Estructura del repositorio

```
G1_CAPSTONE_003D/
├── README.md
├── SECURITY.md
├── .github/workflows/             ← integración continua (backend y frontend)
├── Fase 1/
│   ├── Evidencias Grupales/       ← entregables grupales de la Fase 1
│   └── Evidencias Individuales/   ← autoevaluaciones y diarios por integrante
└── Fase 2/
    ├── Codigo/                    ← backend, base de datos, aplicación, panel y reloj
    ├── Evidencias Grupales/       ← guía del estudiante y planilla de evaluación
    ├── Evidencias Individuales/   ← autoevaluación del avance
    └── Evidencias Proyecto/       ← documentos del avance y evidencias de cierre
```

---

## 11. Licencia y uso

Material de **uso académico**, elaborado para la asignatura Capstone (APT122) de Duoc UC. No se autoriza su uso, reproducción ni distribución con fines distintos al académico sin autorización expresa del equipo y de las partes involucradas.

---

<div align="center">

**AgeCare** · Capstone APT122 · Grupo 1 · Sección 003D
Ingeniería en Informática · Sede San Andrés · **Duoc UC** · 2026

*Cuidando a quienes cuidaron de nosotros.*

</div>

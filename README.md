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
> El proyecto se desarrolla bajo un **acuerdo de confidencialidad**. En consecuencia, este repositorio contiene **únicamente los entregables académicos** del equipo y **no incluye** información confidencial del proyecto asociado: código fuente del producto, diseños internos, modelos de datos, datos reales, credenciales ni información de negocio.
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
9. [Fase 2 — Evidencias (Avance)](#9-fase-2--evidencias-avance)
10. [Estructura del repositorio](#10-estructura-del-repositorio)
11. [Licencia y uso](#11-licencia-y-uso)

---

## 1. Descripción

**AgeCare** es una propuesta de plataforma digital orientada a apoyar el cuidado de adultos mayores y a mejorar la coordinación entre las personas involucradas en ese cuidado: familia, cuidadores, personal de salud y la propia persona mayor.

Este repositorio reúne la evidencia académica del equipo correspondiente a la **Fase 1 — Definición del Proyecto** y al **avance de la Fase 2 — Diseño** (modelo de datos relacional y documentación técnica asociada).

---

## 2. Contexto y motivación

Chile atraviesa un proceso acelerado de envejecimiento poblacional, lo que incrementa la necesidad de herramientas que apoyen el cuidado de las personas mayores y faciliten la coordinación entre quienes las asisten. AgeCare aborda esta necesidad como **caso de estudio académico**, priorizando la accesibilidad, la seguridad de la información y la coordinación entre los distintos roles.

---

## 3. Alcance de este repositorio

**Incluye:**
- Evidencia grupal e individual de la Fase 1 (definición del proyecto).
- Avance de la Fase 2 (diseño): requerimientos funcionales, modelo relacional, diccionario de datos, normalización, análisis de realidad y decisiones, y esquema SQL.
- Documentación académica de carácter general.

**No incluye (por confidencialidad):**
- Código fuente del producto.
- Diseño de arquitectura detallado, modelos de datos internos y especificaciones técnicas.
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
| 3 | Implementación (backend) | En progreso |
| 4 | Implementación (frontend) | Pendiente |
| 5 | Pruebas y calidad | Pendiente |
| 6 | Despliegue y cierre | Pendiente |

---

## 6. Aseguramiento de calidad

Como práctica del equipo se aplican lineamientos de ingeniería de software: control de versiones, revisión entre pares, gestión formal de cambios y documentación versionada por entrega. Los criterios y el plan de pruebas se detallan en las fases correspondientes, en entornos de trabajo internos.

---

## 7. Seguridad y protección de datos

La seguridad se aborda desde el inicio del proyecto (*security by design*), bajo los siguientes principios:

- **Confidencialidad:** no se publican datos sensibles, secretos ni credenciales en este repositorio.
- **Mínimo privilegio:** el acceso a la información se otorga según el rol.
- **Cumplimiento normativo:** el tratamiento de datos personales se ajusta a la normativa chilena vigente en la materia.
- **Trazabilidad:** control de versiones y registro de cambios sobre la documentación.

Los mecanismos técnicos específicos se gestionan en entornos privados y **no forman parte de este repositorio académico**.

---

## 8. Fase 1 — Evidencias

- **Evidencias Grupales:** documentos de definición y evaluación del proyecto.
- **Evidencias Individuales:** autoevaluación de competencias, diario de reflexión y autoevaluación de cada integrante.

---

## 9. Fase 2 — Evidencias (Avance)

La Fase 2 corresponde al **avance de diseño del proyecto** y entrega la documentación técnica que sustenta la base de datos. Se adopta un **enfoque tradicional (modelo relacional)**, con la documentación redactada en **español**.

### Enfoque tradicional (modelo relacional)

- **Documento de Requerimientos Funcionales:** especificación de las funcionalidades que debe cubrir el sistema.
- **Modelo Relacional (en español):** diseño del modelo de datos relacional del proyecto. La documentación se encuentra en español; de haber elementos en inglés, se incorpora el **Diccionario de Datos** correspondiente.
- **Diccionario de Datos:** descripción de tablas, campos, tipos y restricciones del modelo.

> Nota: este proyecto utiliza un **motor relacional**, por lo que no aplica el detalle de colecciones de un motor no relacional.

### Evidencias de Proyecto

| Documento | Descripción |
|-----------|-------------|
| `00_ERS_Simplificado_Fase1.docx` | Especificación de Requerimientos de Software (simplificada). |
| `01_Documento_Requerimientos_Funcionales.docx` | Documento de requerimientos funcionales. |
| `02_Modelo_Relacional_Definitivo.docx` | Modelo relacional definitivo (en español). |
| `03_Diccionario_de_Datos.docx` | Diccionario de datos del modelo relacional. |
| `04_Normalizacion_2FN.docx` | Proceso de normalización hasta 2FN. |
| `05_Analisis_de_Realidad_y_Decisiones.docx` | Análisis de realidad y decisiones de diseño. |
| `07_schema_completo.sql` | Script SQL del esquema completo de la base de datos. |

### Otras evidencias de la Fase 2

- **Evidencias Grupales:** guía del estudiante de la fase y planilla de evaluación del avance.
- **Evidencias Individuales:** autoevaluación del avance de la Fase 2 de cada integrante (Benjamín Camus, Javier Cerna y Juan Mora).

---

## 10. Estructura del repositorio

```
G1_CAPSTONE_003D/
├── README.md
├── Fase 1/
│   ├── Evidencias Grupales/       ← entregables grupales de la Fase 1
│   └── Evidencias Individuales/   ← autoevaluaciones y diarios por integrante
└── Fase 2/
    ├── Evidencias Grupales/       ← guía del estudiante y planilla de evaluación
    ├── Evidencias Individuales/   ← autoevaluación del avance
    └── Evidencias Proyecto/       ← requerimientos, modelo relacional, diccionario,
                                      normalización, análisis y esquema SQL
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

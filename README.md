<div align="center">

<img src="https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRBUB5NxN49OL9L-_ZM5faV-gPJEJonlr7K1WY057Dq&s=10" alt="Alloxtentric Logo" width="160"/>
&nbsp;&nbsp;&nbsp;&nbsp;
<img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/a/aa/Logo_DuocUC.svg/3840px-Logo_DuocUC.svg.png" alt="Duoc UC Logo" width="220"/>

# 🩺 AgeCare
### Plataforma Digital Integral de Cuidado de Adultos Mayores

[![FastAPI](https://img.shields.io/badge/Backend-FastAPI-009688?style=for-the-badge&logo=fastapi)](https://fastapi.tiangolo.com/)
[![Flutter](https://img.shields.io/badge/Mobile-Flutter-02569B?style=for-the-badge&logo=flutter)](https://flutter.dev/)
[![PostgreSQL](https://img.shields.io/badge/DB-PostgreSQL-336791?style=for-the-badge&logo=postgresql)](https://www.postgresql.org/)
[![Azure](https://img.shields.io/badge/Cloud-Microsoft_Azure-0078D4?style=for-the-badge&logo=microsoftazure)](https://azure.microsoft.com/)
[![Docker](https://img.shields.io/badge/Infra-Docker-2496ED?style=for-the-badge&logo=docker)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-Academic-blueviolet?style=for-the-badge)](./LICENSE)

**Capstone APT122 · PTY4614 · Grupo 1 · Sección 003D**
**Ingeniería en Informática — Sede San Andrés · Duoc UC**

</div>

---

## 📋 Tabla de Contenidos

- [🔍 Contexto y Problemática](#-contexto-y-problemática)
- [💡 Descripción del Proyecto](#-descripción-del-proyecto)
- [🎯 Objetivos](#-objetivos)
- [👥 Equipo](#-equipo)
- [🏗️ Arquitectura del Sistema](#️-arquitectura-del-sistema)
- [🛠️ Stack Tecnológico](#️-stack-tecnológico)
- [📐 Metodología](#-metodología)
- [📅 Carta Gantt](#-carta-gantt)
- [📦 Fases del Proyecto](#-fases-del-proyecto)
- [📁 Evidencias](#-evidencias)
- [🎓 Competencias del Perfil de Egreso](#-competencias-del-perfil-de-egreso)
- [📊 Rúbrica de Evaluación](#-rúbrica-de-evaluación)
- [📂 Estructura del Repositorio](#-estructura-del-repositorio)
- [⚙️ Instalación y Ejecución](#️-instalación-y-ejecución)
- [🔐 Seguridad](#-seguridad)
- [📖 Documentación Adicional](#-documentación-adicional)

---

## 🔍 Contexto y Problemática

### El problema

Chile enfrenta un acelerado proceso de envejecimiento poblacional. Según proyecciones del INE, para 2050 más del **22% de la población será mayor de 65 años**. Este fenómeno genera una presión creciente sobre los sistemas de salud, las familias y los cuidadores formales e informales.

Hoy en día, el cuidado de adultos mayores se caracteriza por:

| Problema | Impacto |
|----------|---------|
| 🔴 Fragmentación de información clínica | Retrasos en respuesta ante emergencias |
| 🔴 Falta de coordinación entre familia y cuidadores | Errores en medicación y seguimiento |
| 🔴 Ausencia de monitoreo continuo a distancia | Incidentes no detectados a tiempo |
| 🔴 Interfaces tecnológicas poco accesibles para adultos mayores | Baja adopción de herramientas digitales |
| 🔴 Inexistencia de un canal unificado de comunicación | Información dispersa en llamadas, mensajes y papeles |

### Relevancia sociosanitaria

La descoordinación en el ecosistema de cuidado retarda la toma de decisiones críticas y aumenta el riesgo de complicaciones de salud evitables. **AgeCare** aborda esta brecha mediante una plataforma HealthTech que centraliza monitoreo, alertas, coordinación clínica y asistencia con inteligencia artificial en un único ecosistema digital multi-rol.

---

## 💡 Descripción del Proyecto

**AgeCare** es una plataforma digital integral de cuidado de adultos mayores, compuesta por:

- 📱 **Aplicaciones móviles** para Familias, Cuidadores, Médicos y el propio Adulto Mayor
- 🖥️ **Panel web administrativo** para gestión clínica centralizada
- 🤖 **Asistente IA generativa** para soporte clínico contextualizado
- 📡 **Telemetría de signos vitales** en tiempo real desde wearables
- 🔔 **Sistema de alertas críticas** automatizadas y escaladas
- 🧾 **OCR de recetas médicas** para digitalización y adherencia farmacológica
- 🎵 **Módulo "Director Musical"** — interfaz cognitiva accesible para adultos mayores

### Roles de usuario

```
┌──────────────────────────────────────────────────────────────────────┐
│                          AgeCare Platform                            │
├──────────────┬──────────────────┬────────────────────┬──────────────┤
│  👴 Adulto   │  👩‍⚕️ Cuidador/a  │  👨‍👩‍👧 Familiar      │  🩺 Médico   │
│   Mayor      │                  │                    │              │
│              │                  │                    │              │
│ • Dictado voz│ • Historial      │ • Monitoreo remoto │ • Historial  │
│ • Recordato- │   clínico        │ • Alertas críticas │   clínico    │
│   rios       │ • Gestión meds   │ • Dashboard        │ • Recetas    │
│ • Dir. Musical│ • Reportes     │ • Comunicación     │ • Evolución  │
│ • Alertas    │ • Alertas        │ • OCR recetas      │ • Indicadores│
└──────────────┴──────────────────┴────────────────────┴──────────────┘
```

---

## 🎯 Objetivos

### Objetivo General

> Desarrollar y desplegar la plataforma **AgeCare** para centralizar el monitoreo de salud, alertas y coordinación clínica entre familiares, cuidadores, médicos y el adulto mayor, garantizando seguridad de datos y optimizando tiempos de reacción ante eventos críticos de salud.

### Objetivos Específicos

| # | Objetivo | Métrica de Éxito |
|---|----------|-----------------|
| 1 | ⚡ Reducir el tiempo de respuesta ante emergencias médicas | **-40%** en los primeros 3 meses (notificaciones push alta criticidad) |
| 2 | 💊 Aumentar adherencia farmacológica mediante recordatorios y OCR | **+35%** en el primer semestre |
| 3 | 👴 Lograr adopción diaria activa del adulto mayor | **80%** al segundo mes (interfaz accesible + dictado de voz) |
| 4 | 🚀 Garantizar rendimiento y disponibilidad de la plataforma | Latencia **<500ms (p95)** · Uptime **99.9%** en Azure |

---

## 👥 Equipo

<div align="center">

| 👤 Integrante | 🎓 RUT | 🛠️ Rol en el Proyecto | 💼 Perfil Técnico |
|--------------|--------|----------------------|------------------|
| **Javier Cerna Chávez** | 20.439.385-0 | Tech Lead · Full Stack · IA · DevSecOps | Backend avanzado, hardware embebido (ESP32, Arduino, Raspberry Pi), LLMs locales, CI/CD |
| **Benjamín Camus Jara** | 21.595.258-4 | Arquitecto de Datos · Data Engineering · Azure | DBA, modelado datos, arquitectura híbrida PostgreSQL + NoSQL, optimización Cloud |
| **Juan Pablo Mora Rosales** | 21.718.316-2 | DBA · Modelado Relacional | Administración de bases de datos, diseño ER, normalización |

</div>

**Carrera:** Ingeniería en Informática | **Sede:** San Andrés | **Año de Ingreso:** 2023
**Asignatura:** PTY4614 Capstone | **Código:** APT122

---

## 🏗️ Arquitectura del Sistema

```
                        ┌─────────────────────────────────────────┐
                        │           MICROSOFT AZURE CLOUD          │
                        │                                          │
  📱 Flutter App   ───► │  ┌─────────────────────────────────┐    │
  (Adulto Mayor)        │  │     Azure Container Apps         │    │
                        │  │                                  │    │
  📱 Flutter App   ───► │  │  ┌──────────┐  ┌─────────────┐  │    │
  (Cuidador/a)          │  │  │ FastAPI  │  │  AI Service │  │    │
                        │  │  │ Backend  │◄─► (Azure OpenAI│  │    │
  📱 Flutter App   ───► │  │  │  (Python)│  │    / LLMs)  │  │    │
  (Familiar)            │  │  └────┬─────┘  └─────────────┘  │    │
                        │  │       │                           │    │
  🖥️ Web Panel    ───► │  │  ┌────▼────────────────────────┐  │    │
  (Admin)               │  │  │         Data Layer          │  │    │
                        │  │  │  ┌────────────┐ ┌────────┐  │  │    │
  ⌚ Wearable      ───► │  │  │  │ PostgreSQL │ │ NoSQL  │  │  │    │
  (Telemetría)          │  │  │  │ (Históricos│ │(Teleme-│  │  │    │
                        │  │  │  │  /Transacc)│ │ tría)  │  │  │    │
                        │  │  │  └────────────┘ └────────┘  │  │    │
                        │  │  └────────────────────────────┘  │    │
                        │  └─────────────────────────────────┘    │
                        │                                          │
                        │  🔐 JWT · Cifrado E2E · DevSecOps        │
                        └─────────────────────────────────────────┘
                        
  Containerización: Docker + docker-compose
  Pruebas: Postman · PyTest
  OCR: Reconocimiento óptico de recetas médicas
```

### Capas del sistema

| Capa | Tecnología | Descripción |
|------|-----------|-------------|
| 📱 Presentación | Flutter (Dart) | Apps móviles multi-rol + panel web |
| ⚙️ Lógica de Negocio | FastAPI (Python) | API REST, autenticación JWT, orquestación |
| 🤖 Inteligencia Artificial | Azure OpenAI / LLMs | Asistente clínico contextual, OCR recetas |
| 🗄️ Persistencia | PostgreSQL + NoSQL | Datos clínicos estructurados + telemetría |
| ☁️ Infraestructura | Microsoft Azure | Container Apps, escalabilidad, alta disponibilidad |
| 🔐 Seguridad | JWT + cifrado E2E | Autenticación, autorización, DevSecOps |

---

## 🛠️ Stack Tecnológico

<div align="center">

### Backend
![Python](https://img.shields.io/badge/Python-3776AB?style=flat-square&logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-009688?style=flat-square&logo=fastapi&logoColor=white)
![JWT](https://img.shields.io/badge/JWT-000000?style=flat-square&logo=jsonwebtokens&logoColor=white)

### Frontend / Mobile
![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=flat-square&logo=dart&logoColor=white)

### Base de Datos
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-336791?style=flat-square&logo=postgresql&logoColor=white)
![NoSQL](https://img.shields.io/badge/NoSQL-E34F26?style=flat-square&logo=mongodb&logoColor=white)

### Cloud e Infraestructura
![Azure](https://img.shields.io/badge/Microsoft_Azure-0078D4?style=flat-square&logo=microsoftazure&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white)

### IA y ML
![OpenAI](https://img.shields.io/badge/Azure_OpenAI-412991?style=flat-square&logo=openai&logoColor=white)

### Testing
![Postman](https://img.shields.io/badge/Postman-FF6C37?style=flat-square&logo=postman&logoColor=white)
![PyTest](https://img.shields.io/badge/PyTest-0A9EDC?style=flat-square&logo=pytest&logoColor=white)

</div>

### Detalle del stack

| Categoría | Tecnología | Versión / Detalles |
|-----------|-----------|-------------------|
| 🐍 Lenguaje Backend | Python | 3.11+ |
| ⚡ Framework API | FastAPI | REST API, async, OpenAPI docs |
| 📱 Framework Mobile | Flutter | Dart, multiplataforma iOS/Android |
| 🗄️ BD Relacional | PostgreSQL | Historiales clínicos, transacciones |
| 📡 BD No Relacional | NoSQL | Telemetría wearable en tiempo real |
| ☁️ Cloud | Microsoft Azure | Azure Container Apps |
| 🐳 Contenedores | Docker + docker-compose | Orquestación de servicios |
| 🔐 Autenticación | JWT | JSON Web Tokens, cifrado E2E |
| 🤖 IA Generativa | Azure OpenAI / LLMs | Asistente clínico contextual |
| 📄 OCR | Azure OCR / Custom | Digitalización de recetas médicas |
| 🧪 Testing Backend | PyTest | Pruebas unitarias e integración |
| 🧪 Testing API | Postman | Pruebas funcionales y de carga |
| 🔒 Seguridad | DevSecOps | Análisis en pipeline CI/CD |

---

## 📐 Metodología

El proyecto sigue el **modelo de desarrollo en Cascada (Waterfall)**, elegido por la claridad y estabilidad de los requerimientos definidos desde el inicio del proyecto.

```
  S1─S3        S4─S6        S7─S11       S12─S14      S15─S16      S17─S18
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
│ Análisis │─►│  Diseño  │─►│ Impl.    │─►│ Impl.    │─►│ Pruebas  │─►│Despliegue│
│    y     │  │    del   │  │ Backend  │  │Frontend  │  │          │  │          │
│Requisitos│  │ Sistema  │  │   e IA   │  │          │  │          │  │          │
└──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────┘
```

### Etapas detalladas

| Etapa | Semanas | Actividades principales |
|-------|---------|------------------------|
| 📋 **Análisis y Definición de Requisitos** | S1 – S3 | ERS simplificado, alcance MVP, casos de uso, requisitos funcionales y no funcionales |
| 📐 **Diseño del Sistema** | S4 – S6 | Arquitectura Azure, modelo ER en PostgreSQL, diagramas UML (clases, secuencia, casos de uso) |
| ⚙️ **Implementación Backend e IA** | S7 – S11 | FastAPI, integración LLMs, OCR, simulador Wearable, API REST completa |
| 📱 **Implementación Frontend** | S12 – S14 | Flutter apps (3 roles), módulo "Director Musical", integración con API |
| 🧪 **Pruebas** | S15 – S16 | Unitarias, integración, rendimiento (p95 <500ms), seguridad (PyTest + Postman) |
| 🚀 **Despliegue** | S17 – S18 | Docker, Azure Container Apps, Manual Técnico, presentación a comisión evaluadora |

### Factibilidad del proyecto

| Factor | Descripción |
|--------|-------------|
| ✅ **Facilitador 1** | Infraestructura Microsoft Azure disponible para el equipo |
| ✅ **Facilitador 2** | Requerimientos estables y bien definidos desde el inicio |
| ✅ **Facilitador 3** | Experiencia previa del equipo en el stack tecnológico elegido |
| ⚠️ **Obstaculizador** | Integración con hardware real del wearable (latencia y compatibilidad) |
| 🔧 **Solución propuesta** | Implementar un **simulador de ingesta de datos** en las primeras etapas para desbloquear el desarrollo sin depender del hardware físico |

---

## 📅 Carta Gantt

> Duración total del proyecto: **18 semanas**

| Actividad | S1 | S2 | S3 | S4 | S5 | S6 | S7 | S8 | S9 | S10 | S11 | S12 | S13 | S14 | S15 | S16 | S17 | S18 |
|-----------|----|----|----|----|----|----|----|----|----|----|-----|-----|-----|-----|-----|-----|-----|-----|
| 📋 Análisis y Requisitos (ERS) | 🟦 | 🟦 | 🟦 | | | | | | | | | | | | | | | |
| 📐 Diseño de Arquitectura | | | | 🟩 | 🟩 | 🟩 | | | | | | | | | | | | |
| 🗄️ Modelo de Datos (ER PostgreSQL) | | | | 🟩 | 🟩 | 🟩 | | | | | | | | | | | | |
| 📊 Diagramas UML | | | | | 🟩 | 🟩 | | | | | | | | | | | | |
| ⚙️ Implementación Backend (FastAPI) | | | | | | | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | | | | | | | |
| 🤖 Integración IA / LLMs | | | | | | | | 🟨 | 🟨 | 🟨 | 🟨 | | | | | | | |
| 🧾 OCR Recetas Médicas | | | | | | | | | 🟨 | 🟨 | 🟨 | | | | | | | |
| 📡 Simulador Wearable | | | | | | | 🟨 | 🟨 | 🟨 | | | | | | | | | |
| 📱 Implementación Flutter (Apps) | | | | | | | | | | | | 🟧 | 🟧 | 🟧 | | | | |
| 🎵 Módulo "Director Musical" | | | | | | | | | | | | | 🟧 | 🟧 | | | | |
| 🧪 Pruebas Unitarias e Integración | | | | | | | | | | | | | | | 🟥 | 🟥 | | |
| 🔒 Pruebas de Seguridad | | | | | | | | | | | | | | | | 🟥 | | |
| 🐳 Docker + docker-compose | | | | | | | | | | | | | | | | | 🟪 | |
| ☁️ Despliegue Azure Container Apps | | | | | | | | | | | | | | | | | 🟪 | 🟪 |
| 📖 Manual Técnico y Documentación | | | | | | | | | | | | | | | | | 🟪 | 🟪 |
| 🎤 Presentación a Comisión | | | | | | | | | | | | | | | | | | 🟪 |

**Leyenda:** 🟦 Análisis · 🟩 Diseño · 🟨 Backend/IA · 🟧 Frontend · 🟥 Pruebas · 🟪 Despliegue

---

## 📦 Fases del Proyecto

### Fase 1 — Definición del Proyecto ✅
> **Estado:** Completada | **Naturaleza:** Formativa (0% nota final)

Definición completa de la idea de proyecto, equipo, roles, objetivos, metodología y plan de trabajo.

**Entregables:**
- ✅ Documento de definición del proyecto (ERS preliminar)
- ✅ Carta Gantt de 18 semanas
- ✅ Autoevaluación de competencias (individual × 3)
- ✅ Diario de reflexión (individual × 3)
- ✅ Autoevaluación Fase 1 (individual × 3)
- ✅ Presentación idea de proyecto (grupal)
- ✅ Rúbrica de evaluación formativa

---

### Fase 2 — Diseño y Arquitectura 🔄
> **Estado:** En progreso

- Arquitectura definitiva del sistema en Azure
- Modelo Entidad-Relación completo en PostgreSQL
- Diagramas UML: Casos de Uso, Clases, Secuencia
- Definición de requisitos no funcionales (seguridad, rendimiento, escalabilidad)

---

### Fase 3 — Implementación Backend e IA 🔄
> **Estado:** Pendiente

- Desarrollo API REST con FastAPI
- Integración con Azure OpenAI / LLMs para asistente clínico
- Sistema OCR para recetas médicas
- Simulador de telemetría de wearable
- Autenticación JWT y cifrado de extremo a extremo

---

### Fase 4 — Implementación Frontend 🔄
> **Estado:** Pendiente

- Flutter app para Adulto Mayor (dictado voz, módulo cognitivo "Director Musical")
- Flutter app para Cuidador/a (historial clínico, gestión de medicamentos)
- Flutter app para Familiar (monitoreo remoto, alertas)
- Panel web administrativo

---

### Fase 5 — Pruebas y Calidad 🔄
> **Estado:** Pendiente

- Pruebas unitarias con PyTest
- Pruebas de integración con Postman
- Pruebas de rendimiento (latencia p95 < 500ms)
- Pruebas de seguridad (análisis de vulnerabilidades, DevSecOps)

---

### Fase 6 — Despliegue y Cierre 🔄
> **Estado:** Pendiente

- Containerización con Docker y docker-compose
- Despliegue en Azure Container Apps
- Manual Técnico completo
- Presentación final a comisión evaluadora

---

## 📁 Evidencias

| # | Tipo | Nombre | Descripción |
|---|------|--------|-------------|
| 1 | 📄 Final | Documento de Requerimientos y Arquitectura | ERS simplificado + diagrama de arquitectura (FastAPI, Flutter, Azure) |
| 2 | 📊 Avance | Modelo de Datos | Esquema Entidad-Relación en PostgreSQL para telemetría clínica |
| 3 | 📐 Avance | Diagramas UML Mínimos | Casos de uso, clases y secuencia para flujos principales (Alertas, Monitoreo) |
| 4 | 🔒 Avance | Requisitos No Funcionales | Seguridad (JWT/cifrado), rendimiento, escalabilidad, disponibilidad |
| 5 | 🐳 Final | Configuración Docker | Dockerfile, docker-compose.yml, variables de entorno |
| 6 | 🧪 Final | Pruebas Integrales | Casos de prueba: unitarios, integración, rendimiento y seguridad |
| 7 | 💡 Final | Innovación (Cierre) | Valor agregado, diferenciadores técnicos (IA/OCR), problemas resueltos |

---

## 🎓 Competencias del Perfil de Egreso

Las competencias del programa de **Ingeniería en Informática** que se desarrollan en este proyecto:

| Competencia | Descripción | Roles involucrados |
|-------------|-------------|-------------------|
| 🧪 **Certificación de Productos** | Realizar pruebas de certificación de productos y procesos siguiendo buenas prácticas de la industria | Todo el equipo |
| 📋 **Gestión de Proyectos** | Planificar, controlar y tomar decisiones en la gestión de proyectos informáticos | Todo el equipo |
| 🗄️ **Modelos de Datos Escalables** | Diseñar e implementar modelos de datos que escalen según las necesidades del sistema | Benjamín Camus · Juan Mora |
| ⚙️ **Desarrollo de Soluciones Software** | Construir, integrar e implantar soluciones sistematizando el proceso de desarrollo | Javier Cerna · Todo el equipo |

### Niveles de dominio autoevaluados

| Competencia | Javier Cerna | Benjamín Camus | Juan Mora |
|-------------|:------------:|:--------------:|:---------:|
| Ciberseguridad y Gestión de Riesgos | 🟢 Alto | 🔵 Excelente | 🟢 Alto |
| Desarrollo de Soluciones y Arquitectura | 🟢 Alto | 🟢 Alto | 🟡 Aceptable |
| Gestión y Evaluación de Proyectos | 🟢 Alto | 🟢 Alto | 🟢 Alto |
| Administración de Datos e IA de Negocios | 🟢 Alto | 🔵 Excelente | 🟢 Alto |

**Escala:** 🔵 Excelente Dominio · 🟢 Alto Dominio · 🟡 Dominio Aceptable

---

## 📊 Rúbrica de Evaluación

### Fase 1 — Evaluación Formativa (12 indicadores)

| # | Indicador | Ponderación |
|---|-----------|:-----------:|
| 1 | Descripción y relevancia del proyecto | 5% |
| 2 | Relación con perfil de egreso | 5% |
| 3 | Relación con intereses profesionales del equipo | 5% |
| 4 | Factibilidad del proyecto | 5% |
| 5 | Objetivos claros y coherentes | 10% |
| 6 | Metodología de trabajo pertinente | 10% |
| 7 | Plan de trabajo con recursos y tiempos | 10% |
| 8 | Evidencias justificadas | 10% |
| 9 | Redacción, ortografía y citas | 5% |
| 10 | Formato del informe | 5% |
| 11 | Indicadores de calidad disciplinarios | 20% |
| 12 | Comunicación escrita en inglés (nivel intermedio alto) | 10% |
| | **Total** | **100%** |

**Escala de logro:**

| Nivel | Descripción | % |
|-------|-------------|---|
| ✅ Completamente Logrado | El indicador se cumple de forma completa y rigurosa | 100% |
| 🟡 Logrado | El indicador se cumple con observaciones menores | 60% |
| 🟠 Logro Incipiente | Cumplimiento parcial con aspectos relevantes faltantes | 30% |
| ❌ No Logrado | El indicador no se cumple | 0% |

> ⚠️ **Nota:** La Fase 1 es de carácter **formativo** y tiene ponderación **0%** sobre la nota final del Capstone.

---

## 📂 Estructura del Repositorio

```
G1_CAPSTONE_003D/
│
├── 📁 Fase 1/
│   ├── 📁 Evidencias Grupales/
│   │   ├── 📄 1.4_APT122_FormativaFase1.docx              # Rúbrica evaluación
│   │   ├── 📄 1.5_GuiaEstudiante_Fase1_Definicion.docx    # Guía y definición proyecto
│   │   ├── 📊 PLANILLA DE EVALUACIÓN FASE 1.xlsx          # Planilla calificaciones
│   │   └── 📊 Presentación idea de proyecto.pptx          # Presentación grupal
│   │
│   └── 📁 Evidencias Individuales/
│       ├── 📄 Camus_Benjamín_1.1_..._AutoevalCompetencias.docx
│       ├── 📄 Camus_Benjamín_1.2_..._DiarioReflexion.docx
│       ├── 📄 Camus_Benjamín_1.3_..._AutoevalFase1.docx
│       ├── 📄 Cerna_Javier_1.1_..._AutoevalCompetencias.docx
│       ├── 📄 Cerna_Javier_1.2_..._DiarioReflexion.docx
│       ├── 📄 Cerna_Javier_1.3_..._AutoevalFase1.docx
│       ├── 📄 Mora_Juan_1.1_..._AutoevalCompetencias.docx
│       ├── 📄 Mora_Juan_1.2_..._DiarioReflexion.docx
│       └── 📄 Mora_Juan_1.3_..._AutoevalFase1.docx
│
├── 📁 Fase 2/                # (Próximamente)
├── 📁 Fase 3/                # (Próximamente)
├── 📁 src/                   # (Código fuente — próximamente)
│   ├── 📁 backend/           # FastAPI application
│   ├── 📁 mobile/            # Flutter apps
│   └── 📁 infrastructure/    # Docker + Azure configs
│
└── 📄 README.md
```

---

## ⚙️ Instalación y Ejecución

> 🚧 Esta sección se completará durante la Fase 3 (Implementación). Los siguientes comandos son referenciales.

### Prerrequisitos

```bash
# Versiones requeridas
Python 3.11+
Flutter 3.x
Docker 24+
PostgreSQL 15+
```

### Backend (FastAPI)

```bash
# Clonar el repositorio
git clone https://github.com/duocuc/G1_CAPSTONE_003D.git
cd G1_CAPSTONE_003D/src/backend

# Instalar dependencias
pip install -r requirements.txt

# Configurar variables de entorno
cp .env.example .env
# Editar .env con tus credenciales

# Ejecutar en desarrollo
uvicorn main:app --reload --port 8000
```

### Frontend (Flutter)

```bash
cd src/mobile

# Instalar dependencias
flutter pub get

# Ejecutar en dispositivo/emulador
flutter run
```

### Con Docker (recomendado)

```bash
# Levantar todos los servicios
docker-compose up --build

# Servicios disponibles:
# - API Backend:  http://localhost:8000
# - Docs API:     http://localhost:8000/docs
# - PostgreSQL:   localhost:5432
```

---

## 🔐 Seguridad

AgeCare implementa múltiples capas de seguridad siguiendo el enfoque **DevSecOps**:

| Mecanismo | Descripción |
|-----------|-------------|
| 🔑 **JWT** | Autenticación stateless con tokens firmados |
| 🔒 **Cifrado E2E** | Cifrado de extremo a extremo en comunicaciones |
| 🛡️ **DevSecOps** | Análisis de seguridad integrado en el pipeline CI/CD |
| 🏥 **RBAC** | Control de acceso basado en roles (Familiar / Cuidador / Médico / Admin) |
| 📋 **Auditoría** | Registro de acciones críticas sobre datos clínicos |
| ☁️ **Azure Security** | Configuración de seguridad a nivel de infraestructura cloud |

> ⚠️ Los datos de salud de adultos mayores se tratan conforme a estándares de privacidad y protección de datos sensibles.

---

## 📖 Documentación Adicional

| Documento | Descripción | Estado |
|-----------|-------------|:------:|
| 📋 ERS (Especificación de Requisitos) | Requisitos funcionales y no funcionales del sistema | 🔄 En progreso |
| 📐 Arquitectura del Sistema | Diagrama detallado de componentes y flujos | 🔄 En progreso |
| 🗄️ Modelo de Datos | Esquema ER completo de PostgreSQL | 🔄 En progreso |
| 📊 Diagramas UML | Casos de uso, clases y secuencia | 🔄 En progreso |
| 🧪 Plan de Pruebas | Estrategia de testing y casos de prueba | ⏳ Pendiente |
| 📖 Manual Técnico | Guía de despliegue y operación | ⏳ Pendiente |
| 🎤 Presentación Final | Presentación para comisión evaluadora | ⏳ Pendiente |

---

<div align="center">

---

**AgeCare** · Capstone APT122 · Grupo 1 · Sección 003D

Ingeniería en Informática · Sede San Andrés · **Duoc UC** · 2024–2025

*Cuidando a quienes cuidaron de nosotros* 💙

---

<img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/a/aa/Logo_DuocUC.svg/3840px-Logo_DuocUC.svg.png" alt="Duoc UC" width="120"/>

</div>

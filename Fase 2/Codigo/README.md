<div align="center">

<img src="https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRBUB5NxN49OL9L-_ZM5faV-gPJEJonlr7K1WY057Dq&s=10" alt="Alloxtentric Logo" width="160"/>
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

<sub>¿Quieres entender el contexto académico detrás de este proyecto? → [Visita nuestra Wiki](https://github.com/Jaacern/G1_CAPSTONE_003D/wiki)</sub>

</div>

---

> 📍 **Ubicación:** esta carpeta (`Fase 2/Codigo/`) contiene el **código fuente fullstack**
> de AgeCare (backend, frontend y app de reloj). La documentación académica del proyecto
> (ERS, UML, modelo de datos, autoevaluaciones y evidencias) vive en las carpetas
> `Fase 1/` y `Fase 2/` de este mismo repositorio.

---

## 📋 Tabla de Contenidos

1. [🔍 Contexto y Problemática](#-contexto-y-problemática)
2. [💡 Descripción del Proyecto](#-descripción-del-proyecto)
3. [🎯 Objetivos](#-objetivos)
4. [👥 Equipo](#-equipo)
5. [🏗️ Arquitectura del Sistema](#️-arquitectura-del-sistema)
6. [🛠️ Stack Tecnológico](#️-stack-tecnológico)
7. [📐 Metodología](#-metodología)
8. [📅 Carta Gantt](#-carta-gantt)
9. [📦 Fases del Proyecto](#-fases-del-proyecto)
10. [📂 Estructura del Código](#-estructura-del-código)
11. [⚙️ Instalación y Ejecución](#️-instalación-y-ejecución)
12. [🔐 Seguridad](#-seguridad)
13. [📖 Documentación Adicional](#-documentación-adicional)

---

## 🔍 Contexto y Problemática

### El problema

Chile enfrenta un acelerado proceso de envejecimiento poblacional. Según proyecciones del INE, para 2050 más del **22% de la población será mayor de 65 años**. Este fenómeno genera una presión creciente sobre los sistemas de salud, las familias y los cuidadores formales e informales.

Hoy en día, el cuidado de adultos mayores se caracteriza por:

| 🔴 Problema | 🟢 Impacto |
|------------|-----------|
| 🔴 Fragmentación de información clínica | 🟢 Retrasos en respuesta ante emergencias |
| 🔴 Falta de coordinación entre familia y cuidadores | 🟢 Errores en medicación y seguimiento |
| 🔴 Ausencia de monitoreo continuo a distancia | 🟢 Incidentes no detectados a tiempo |
| 🔴 Interfaces tecnológicas poco accesibles para adultos mayores | 🟢 Baja adopción de herramientas digitales |
| 🔴 Inexistencia de un canal unificado de comunicación | 🟢 Información dispersa en llamadas, mensajes y papeles |

### Relevancia sociosanitaria

La descoordinación en el ecosistema de cuidado retarda la toma de decisiones críticas y aumenta el riesgo de complicaciones de salud evitables. **AgeCare** aborda esta brecha mediante una plataforma HealthTech que centraliza monitoreo, alertas, coordinación clínica y asistencia con inteligencia artificial en un único ecosistema digital multi-rol.

---

## 💡 Descripción del Proyecto

**AgeCare** es una plataforma digital integral de cuidado de adultos mayores, compuesta por:

- 📱 **Aplicaciones móviles** para Familias, Cuidadores, Médicos y el propio Adulto Mayor
- ⌚ **App de reloj (Wear OS)** para captura de signos vitales (pulso) en tiempo real
- 🖥️ **Panel web administrativo** para gestión clínica centralizada
- 🤖 **Asistente IA generativa** para soporte clínico contextualizado
- 📡 **Telemetría de signos vitales** en tiempo real desde wearables
- 🔔 **Sistema de alertas críticas** automatizadas y escaladas
- 🧾 **OCR de recetas médicas** para digitalización y adherencia farmacológica
- 🎵 **Módulo "Director Musical"** — interfaz cognitiva accesible para adultos mayores

### Roles de usuario

```
┌──────────────────────────────────────────────────────────────────────┐
│                          AgeCare Platform                              │
├──────────────┬──────────────────┬────────────────────┬──────────────┤
│ 👴 Adulto    │ 👩‍⚕️ Cuidador/a    │ 👨‍👩‍👧 Familiar       │ 🩺 Médico     │
│   Mayor      │                  │                    │              │
│ • Dictado voz│ • Historial      │ • Monitoreo remoto │ • Historial  │
│ • Recordato- │   clínico        │ • Alertas críticas │   clínico    │
│   rios       │ • Gestión meds   │ • Dashboard        │ • Recetas    │
│ • Dir.Musical│ • Reportes       │ • Comunicación     │ • Evolución  │
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

| 👤 Integrante | 🛠️ Rol en el Proyecto | 💼 Perfil Técnico |
|--------------|----------------------|------------------|
| **Javier Cerna** | Tech Lead · Full Stack · IA · DevSecOps | Backend avanzado, hardware embebido, LLMs locales, CI/CD |
| **Benjamín Camus** | Arquitecto de Datos · Data Engineering · Azure | DBA, modelado de datos, arquitectura híbrida PostgreSQL + NoSQL, optimización Cloud |
| **Juan Mora** | DBA · Modelado Relacional | Administración de bases de datos, diseño ER, normalización |

</div>

**Carrera:** Ingeniería en Informática · **Sede:** San Andrés <br>
**Asignatura:** PTY4614 Capstone · **Código:** APT122

---

## 🏗️ Arquitectura del Sistema

```
┌─────────────────────────────────────────┐
│         MICROSOFT AZURE CLOUD            │
│                                          │
📱 Flutter App ───► │ ┌─────────────────────────────────┐ │
(Adulto Mayor)      │ │     Azure Container Apps        │ │
│                   │ │                                 │ │
📱 Flutter App ───► │ │ ┌──────────┐   ┌─────────────┐  │ │
(Cuidador/a)        │ │ │ FastAPI  │   │ AI Service  │  │ │
│                   │ │ │ Backend  │◄─►│(Azure OpenAI│  │ │
📱 Flutter App ───► │ │ │ (Python) │   │  / LLMs)    │  │ │
(Familiar)          │ │ └────┬─────┘   └─────────────┘  │ │
│                   │ │      │                          │ │
🖥️ Web Panel  ───► │ │ ┌────▼────────────────────────┐ │ │
(Admin)             │ │ │        Data Layer           │ │ │
│                   │ │ │ ┌────────────┐ ┌────────┐   │ │ │
⌚ Wearable   ───► │ │ │ │ PostgreSQL │ │ NoSQL  │   │ │ │
(Telemetría)        │ │ │ │(Históricos)│ │(Teleme-│   │ │ │
│                   │ │ │ │/Transacc.) │ │ tría)  │   │ │ │
│                   │ │ │ └────────────┘ └────────┘   │ │ │
│                   │ │ └─────────────────────────────┘ │ │
│                   │ └─────────────────────────────────┘ │
│       🔐 JWT · Cifrado E2E · DevSecOps   │
└─────────────────────────────────────────┘

Containerización: Docker + docker-compose
Pruebas: Postman · PyTest
OCR: Reconocimiento óptico de recetas médicas
```

### Capas del sistema

| Capa | Tecnología | Descripción |
|------|-----------|-------------|
| 📱 Presentación | Flutter (Dart) | Apps móviles multi-rol + panel web |
| ⌚ Captura | Kotlin (Wear OS) | App de reloj que envía telemetría de pulso al backend |
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
![Kotlin](https://img.shields.io/badge/Kotlin-7F52FF?style=flat-square&logo=kotlin&logoColor=white)

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
| 📱 Framework Mobile | Flutter | Dart, multiplataforma iOS/Android/Web |
| ⌚ App de reloj | Kotlin + Wear OS | Captura de pulso y envío al backend |
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
   S1─S3        S4─S6       S7─S11      S12─S14     S15─S16     S17─S18
┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│ Análisis │─►│ Diseño   │─►│  Impl.   │─►│  Impl.   │─►│ Pruebas  │─►│Despliegue│
│    y     │ │   del    │ │ Backend  │ │ Frontend │ │          │ │          │
│Requisitos│ │ Sistema  │ │  e IA    │ │          │ │          │ │          │
└──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘
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

---

## 📅 Carta Gantt

> Duración total del proyecto: **18 semanas**

| Actividad | **Fase 1 (S1-S4)** | | | | **Fase 2 (S5-S16)** | | | | | | | | | | | | **Fase 3 (S17-S18)** | |
|-----------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| | **1** | **2** | **3** | **4** | **5** | **6** | **7** | **8** | **9** | **10** | **11** | **12** | **13** | **14** | **15** | **16** | **17** | **18** |
| **Análisis y ERS (Requisitos)** | 🟦 | 🟦 | 🟦 | | | | | | | | | | | | | | | |
| **Diseño de Arquitectura y UML** | | | | 🟩 | 🟩 | 🟩 | | | | | | | | | | | | |
| **Implementación: Backend e IA** | | | | | | | 🟨 | 🟨 | 🟨 | 🟨 | 🟨 | | | | | | | |
| **Implementación: Frontend Flutter** | | | | | | | | | | | | 🟧 | 🟧 | 🟧 | | | | |
| **Plan de Pruebas y Certificación** | | | | | | | | | | | | | | | 🟥 | 🟥 | | |
| **Empaquetado Docker y Despliegue** | | | | | | | | | | | | | | | | | 🟪 | |
| **Elaboración de Evidencias (Documental)** | 🟫 | | | 🟫 | | | | | 🟫 | | | | | | 🟫 | | 🟫 | 🟫 |

**Leyenda:** 🟦 Análisis y ERS · 🟩 Diseño de Arquitectura y UML · 🟨 Implementación Backend e IA · 🟧 Implementación Frontend Flutter · 🟥 Pruebas y Certificación · 🟪 Empaquetado y Despliegue · 🟫 Elaboración de Evidencias

---

## 📦 Fases del Proyecto

### Fase 1 — Definición del Proyecto ✅

> **Estado:** Completada | **Naturaleza:** Formativa (0% nota final)

Definición completa de la idea de proyecto, equipo, roles, objetivos, metodología y plan de trabajo.

### Fase 2 — Diseño y Desarrollo 🔄

> **Estado:** En progreso

Arquitectura definitiva del sistema en Azure, modelo Entidad-Relación completo en PostgreSQL, diagramas UML, normalización 2FN, diccionario de datos y desarrollo del backend/frontend.

**Entregables (avance):**

- ✅ ERS simplificado (base Fase 1)
- ✅ Documento de requerimientos funcionales
- ✅ Modelo relacional definitivo + diccionario de datos
- ✅ Normalización 2FN y análisis de decisiones de diseño
- ✅ Esquema SQL completo + diagrama ER
- 🔄 Backend FastAPI e integración con el frontend Flutter

### Fase 3 — Cierre, Pruebas y Despliegue ⏳

> **Estado:** Pendiente

Pruebas unitarias/integración (PyTest + Postman), rendimiento (p95 <500ms), seguridad (DevSecOps), containerización con Docker, despliegue en Azure Container Apps, Manual Técnico y presentación final.

---

## 📂 Estructura del Código

Esta carpeta (`Fase 2/Codigo/`) contiene el código fuente fullstack de AgeCare:

```
Fase 2/Codigo/
│
├── 📁 backend/                 # API FastAPI + PostgreSQL
│   ├── api/
│   │   ├── app/
│   │   │   ├── routers/        # auth, patients, vitals, medications, alerts, health
│   │   │   ├── config.py · db.py · deps.py · errors.py · security.py
│   │   │   └── main.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── sql/                    # Esquema normalizado + seed de desarrollo
│   ├── docker-compose.yml
│   └── .env.example
│
├── 📁 frontend/                # App Flutter (familiar, cuidadora, adulto mayor)
│   ├── lib/
│   │   ├── core/               # Config, red (Dio), tema, router, widgets
│   │   └── features/           # auth, home, patients, health, medications,
│   │                           # alerts, comms, documents, marketplace, etc.
│   ├── assets/                 # Logo e imágenes de marca
│   ├── android/ · ios/ · web/  # Plataformas
│   ├── test/                   # Pruebas de widget y repositorios
│   └── pubspec.yaml
│
├── 📁 watch_app/               # App de reloj (Wear OS, Kotlin)
│   └── app/src/main/           # HeartRateService · VitalsUploader · MainActivity
│
├── 📄 README.md                # Este documento
└── 📄 TESTING.md               # Guía de pruebas
```

---

## ⚙️ Instalación y Ejecución

### Prerrequisitos

```bash
Python 3.11+
Flutter 3.x
Docker 24+ (o Podman)
PostgreSQL 16+
```

### Backend (FastAPI + PostgreSQL)

```bash
cd backend
# Configurar variables de entorno (nunca subas el .env real)
cp .env.example .env
# Edita .env con tus credenciales locales y un JWT_SECRET propio

# Levantar la base de datos y la API con Docker/Podman
docker compose up -d db api      # o: podman compose up -d db api

# Servicios disponibles:
#   - API Backend: http://localhost:8000
#   - Docs API:    http://localhost:8000/docs
#   - PostgreSQL:  localhost:5432
```

### Frontend (Flutter)

```bash
cd frontend
flutter pub get

# Modo demo (sin backend, datos simulados en memoria)
flutter run --dart-define=USE_MOCKS=true

# Conectado al backend local
flutter run -d chrome \
  --dart-define=USE_MOCKS=false \
  --dart-define=API_BASE_URL=http://localhost:8000
```

**Prueba en un teléfono Android por USB** (reenvía el puerto por el cable):

```bash
adb reverse tcp:8000 tcp:8000
flutter run \
  --dart-define=USE_MOCKS=false \
  --dart-define=API_BASE_URL=http://localhost:8000
```

**Credenciales del seed de desarrollo:**

| Rol | Correo | Contraseña |
|-----|--------|------------|
| Familiar | `ja.cernac@duocuc.cl` | `demo1234` |
| Cuidadora | `rosa@cuidados.cl` | `demo1234` |
| Adulto mayor | `elena@agecare.cl` | `demo1234` |

---

## 🔐 Seguridad

AgeCare implementa múltiples capas de seguridad siguiendo el enfoque **DevSecOps**:

| Mecanismo | Descripción |
|-----------|-------------|
| 🔑 **JWT** | Autenticación stateless con tokens firmados y rotación de refresh tokens |
| 🔒 **Cifrado E2E** | Cifrado de extremo a extremo en comunicaciones |
| 🛡️ **DevSecOps** | Análisis de seguridad integrado en el pipeline CI/CD |
| 🏥 **RBAC** | Control de acceso basado en roles (Familiar / Cuidador / Médico / Admin) |
| 📋 **Auditoría** | Registro de acciones críticas sobre datos clínicos |
| ☁️ **Azure Security** | Configuración de seguridad a nivel de infraestructura cloud |

> ⚠️ Los datos de salud de adultos mayores se tratan conforme a estándares de privacidad y protección de datos sensibles. El archivo `.env` con credenciales reales **nunca** se versiona.

---

## 📖 Documentación Adicional

| Documento | Descripción | Estado |
|-----------|-------------|:------:|
| 📋 ERS (Especificación de Requisitos) | Requisitos funcionales y no funcionales del sistema | ✅ Fase 2 |
| 📐 Arquitectura del Sistema | Diagrama detallado de componentes y flujos | ✅ Fase 2 |
| 🗄️ Modelo de Datos | Esquema ER completo de PostgreSQL + diccionario de datos | ✅ Fase 2 |
| 🧪 Guía de Pruebas | Ver [`TESTING.md`](./TESTING.md) | ✅ Fase 2 |
| 📊 Diagramas UML | Casos de uso, clases y secuencia | 🔄 En progreso |
| 📖 Manual Técnico | Guía de despliegue y operación | ⏳ Pendiente |
| 🎤 Presentación Final | Presentación para comisión evaluadora | ⏳ Pendiente |

---

<div align="center">

---

**AgeCare** · Capstone APT122 · Grupo 1 · Sección 003D
Ingeniería en Informática · Sede San Andrés · **Duoc UC** · 2026

*Cuidando a quienes cuidaron de nosotros* 💙

---

<img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/a/aa/Logo_DuocUC.svg/3840px-Logo_DuocUC.svg.png" alt="Duoc UC" width="120"/>

</div>

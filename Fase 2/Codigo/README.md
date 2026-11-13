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
└── 📄 README.md                # Este documento (incluye guía de ejecución y pruebas)
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

**Con los servicios de fondo** (lo que se usa para probar la app completa):

```bash
docker compose up -d --build db api mantenimiento avisos
```

| Servicio | Qué hace |
|----------|----------|
| `db` | PostgreSQL 16 con los datos de la app |
| `api` | La API FastAPI; al partir aplica las migraciones de `sql/` |
| `mantenimiento` | Cada hora marca las dosis vencidas, avisa mediciones fuera de rango y limpia subidas abandonadas |
| `avisos` | Cada 30 segundos manda al teléfono las alertas pendientes y reavisa las críticas sin atender (RF-52) |

`--build` hace falta después de un `git pull` que cambió el backend: sin él
Docker sigue usando la imagen anterior.

#### Instalar las dependencias de Python (local, sin Docker)

> 💡 Si al correr un script de Python sale `ModuleNotFoundError` (por ejemplo
> `No module named 'fastapi'` o `'slowapi'`), es porque faltan las dependencias
> instaladas. No edites `requirements.txt`: ya está completo, solo hay que
> instalarlo. Suele pasar tras un `git pull` que agregó una dependencia nueva.

```bash
cd backend/api

# Crear y activar el entorno virtual (una sola vez)
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate

# Instalar las dependencias (repetir tras cada pull que agregue alguna)
pip install -r requirements.txt
```

> 🚧 **Pendiente (más adelante):** el **OCR de recetas** está en desarrollo; cuando
> se use, necesita el binario `tesseract` en el sistema
> (`sudo apt-get install -y tesseract-ocr tesseract-ocr-spa`). La **guía de
> pruebas** (`python tests/correr.py` con una base Postgres levantada) se
> documentará aquí cuando esté lista.

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
| Familiar | `familiar@agecare.cl` | `agecare123` |
| Cuidadora | `cuidadora@agecare.cl` | `agecare123` |
| Médica | `doctora@agecare.cl` | `agecare123` |
| Adulto mayor | `adultomayor@agecare.cl` | `agecare123` |
| Administrador (panel) | `administrador@agecare.cl` | `agecare123` |

**Revisar la app antes de subir cambios** (lo mismo que corre el CI):

```bash
cd frontend
flutter analyze   # tiene que decir "No issues found!": el CI falla hasta por un aviso (info)
flutter test      # todas las pruebas
```

---

## 🔐 Seguridad

AgeCare se construye con enfoque **DevSecOps**: la seguridad no es una capa que se
añade al final, sino un control que acompaña cada cambio. Las garantías base del
sistema son:

| Mecanismo | Descripción |
|-----------|-------------|
| 🔑 **JWT** | Autenticación stateless con tokens firmados (HS256) y rotación de refresh tokens con detección de reuso |
| 🧱 **Reconocimiento estricto de entrada (LangSec)** | Todo input se valida contra un esquema tipado (Pydantic) en el borde, antes de procesarse; los enums cierran los valores aceptados |
| 🏥 **RBAC por recurso** | Autorización por membresía viva en cada paciente (`patient_members`), no solo por rol global |
| 🚦 **Rate limiting** | Límite por IP en login, refresh, vinculación de dispositivos, SOS e IA/voz (SlowAPI) |
| 🗄️ **SQL parametrizado** | Todas las consultas usan parámetros; el SQL dinámico solo compone identificadores desde listas blancas del servidor |
| 📋 **Auditoría** | Registro de acciones críticas sobre datos clínicos |

> ⚠️ Los datos de salud de adultos mayores se tratan conforme a estándares de
> privacidad y protección de datos sensibles. El archivo `.env` con credenciales
> reales **nunca** se versiona (está en `.gitignore`).

### 🛡️ Auditoría de seguridad ofensiva (Red Team + DevSecOps)

Dado que gran parte del código se produjo con asistencia de **IA generativa**, se
realizó una **auditoría de seguridad ofensiva** sobre todo el monorepo, con el
criterio de que *el código asistido por IA es verosímil pero no confiable por
defecto*: compila, luce idiomático y suele traer controles "de fachada" (un
chequeo que existe pero que nada activa, una validación por lista negra, un
secreto de ejemplo que se cuela a producción). Esos son precisamente los patrones
que un atacante busca.

**Marcos aplicados:** OWASP Top 10 (web), OWASP API Security Top 10, OWASP Mobile
Top 10, revisión de CVE de dependencias, endurecimiento de contenedores y
principios **LangSec** (*Language-theoretic Security*: reconocer por completo el
lenguaje de entrada antes de procesarlo, y rechazar lo ambiguo).

#### Cómo se aplica el estándar en un monorepo como el nuestro

El repo mezcla documentación académica, backend Python, frontend Dart, app de
reloj Kotlin, SQL e infraestructura. La auditoría se organizó **por superficie de
ataque y límite de confianza**, no por carpeta:

- **Borde HTTP (backend):** autenticación, sesiones, autorización por recurso
  (IDOR/BOLA), inyección SQL, SSRF, manejo de archivos, rate limiting.
- **Cliente (frontend/app):** almacenamiento de tokens, secretos embebidos,
  comunicación en claro, apertura de URLs/esquemas, logging sensible.
- **Cadena de suministro:** CVE de dependencias (`requirements.txt`, `pubspec.yaml`).
- **Infraestructura:** `Dockerfile`, `docker-compose.yml`, manejo de secretos.
- **Fuera de alcance de código:** la documentación y las evidencias no se auditan
  como software, pero sí se verifica que no filtren secretos.

Cada hallazgo exige un **límite de confianza real cruzado** (un principal de menor
privilegio, un recurso afectado y un resultado concreto); no se reportan "malas
prácticas" sin impacto demostrable. Los fixes son el cambio mínimo que restablece
la invariante en el último punto de decisión confiable.

#### Hallazgos y remediación

| ID | Hallazgo | Marco | Severidad | Estado |
|----|----------|-------|:---------:|:------:|
| **F1** | Bloqueo por intentos del código de vinculación era cosmético (`attempts` nunca se incrementaba) | A07 / API | 🔴 Crítico | ✅ Corregido |
| **F2** | API key de proveedor de IA viva en `.env` del working tree / respaldos | A05 | 🟠 Alto | 🔑 Rotación (operativa) |
| **F3** | Sin rate limiting en toda la API (fuerza bruta y abuso de recursos) | A07 / API4 | 🟠 Alto | ✅ Corregido |
| **F4** | Login sin freno a intentos fallidos | A07 | 🟠 Alto | ✅ Corregido |
| **F5** | Secreto JWT por defecto con *fallback silencioso* en config y compose | A02 / A05 | 🟠 Alto | ✅ Corregido |
| **F6** | Dependencias con CVE: `python-jose 3.3.0 → 3.5.0`, `python-multipart 0.0.12 → 0.0.31` (DoS de parser — caso LangSec) | A06 | 🟡 Medio | ✅ Corregido |
| **F7** | Tokens de sesión en `localStorage` (Flutter Web) | Mobile M9 | 🟡 Medio | 📋 Planificado |
| **F8** | Rol `caregiver` puede recetar/editar/suspender medicación | A01 / API5 | 🟡 Medio | 📋 Por decisión de producto |

**Verificado y sin hallazgos** (defensa ya correcta): inyección SQL (parametrización
+ listas blancas), IDOR/BOLA a nivel de objeto en los 19 routers, SSRF (las URLs
salientes solo provienen de configuración, no de entrada del usuario), inyección de
comandos y deserialización (ausentes), rotación y detección de reuso de refresh
tokens, hashing de contraseñas (bcrypt) y de tokens (SHA-256), y la *no*
explotabilidad del `alg:none` / confusión de algoritmos de `python-jose` porque el
código fija `algorithms=["HS256"]` de forma explícita.

#### Correcciones aplicadas en esta entrega

- **F1 — Conteo real de intentos del código de vinculación** (`routers/devices.py`):
  cada intento fallido sobre un código vigente incrementa `attempts` (capado en el
  máximo para no violar el `CHECK` de la tabla) y lo bloquea con `429`. La defensa
  contra la fuerza bruta *ciega* (sin conocer el paciente) la aporta el rate limiting
  por IP de F3, porque un código errado no coincide con ninguna fila y no habría
  contador que tocar — las dos capas se complementan.
- **F3 / F4 — Rate limiting por IP** (`app/ratelimit.py`, `app/main.py`): SlowAPI con
  límites por endpoint sensible (login, refresh, vinculación, SOS, IA/voz), con el
  error traducido al formato estándar (`RATE_LIMITED`, `429`).
- **F5 — Arranque seguro del secreto JWT** (`app/config.py`, `app/main.py`,
  `docker-compose.yml`): la API **se niega a arrancar** si `JWT_SECRET` falta, es el
  valor por defecto del repo o es demasiado corto. Se eliminó el `fallback` silencioso
  del `docker-compose`. Mejor no servir que servir firmando con un secreto público.
- **F6 — Actualización de dependencias con CVE** (`requirements.txt`): `python-jose`
  `3.3.0 → 3.5.0` (CVE-2024-33663/33664, el *JWT bomb* por JWE) y `python-multipart`
  `0.0.12 → 0.0.31` (serie de CVE de DoS del parser: ReDoS de `Content-Type`,
  preámbulo/epílogo, cabeceras sin límite, `Content-Length` negativo). Son fallos
  **LangSec** de libro: parsers que aceptan entrada malformada y colapsan; la versión
  nueva es un reconocedor más estricto. No se actualizó a ciegas — se reconstruyó la
  imagen y se validó auth (login/refresh/me) y subida multipart contra Postgres real
  antes de fijar las versiones, sin regresiones.

> **Validación:** los fixes se probaron contra el backend real (contenedores levantados):
> arranque rechazado sin secreto, login cortado al superar el límite, uso legítimo intacto
> tras la ventana, y el contador de intentos clavándose en el máximo sin romper el esquema.
> Lo que **no** se pudo validar sin un despliegue productivo (config de secretos, DoS bajo
> carga de F6, CSP del hosting web) queda señalado explícitamente en el informe de auditoría.

#### Nota sobre desarrollo asistido por IA

El uso de IA aceleró la construcción, pero introdujo una clase de riesgo propia:
controles que *parecen* implementados. F1 es el caso de libro — el comentario, el
`CHECK` en SQL y el chequeo en Python afirmaban un bloqueo que **nunca se ejecutaba**.
Por eso la postura del proyecto es tratar todo código generado como no confiable hasta
auditarlo, y verificar el comportamiento contra el sistema real, no contra lo que el
código dice que hace.

*Auditoría y remediación: **Javier Cerna (jaacern)** — rol Tech Lead · DevSecOps · Red Team.*

---

## 📖 Documentación Adicional

| Documento | Descripción | Estado |
|-----------|-------------|:------:|
| 📋 ERS (Especificación de Requisitos) | Requisitos funcionales y no funcionales del sistema | ✅ Fase 2 |
| 📐 Arquitectura del Sistema | Diagrama detallado de componentes y flujos | ✅ Fase 2 |
| 🗄️ Modelo de Datos | Esquema ER completo de PostgreSQL + diccionario de datos | ✅ Fase 2 |
| 🧪 Guía de Pruebas | Ver [Instalación y Ejecución](#️-instalación-y-ejecución) → *Backend en local sin Docker* | ✅ Fase 2 |
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

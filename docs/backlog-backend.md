# Backlog de desarrollo y pruebas del backend Salud-U

Fuente principal: `Proyecto Daniel Mercado v2 db.md`, cuadros 3.16 (RF-01–RF-34), 3.17 (RNF-01–RNF-12), 3.18 (RN-01–RN-32), 3.36 (UC-01–UC-27) y especificaciones críticas de UC-07/12/13/15/17/22. Referencia de implementación: 24 rutas `src/app/api`, Server Actions, consultas directas y SQL de `supabase/migrations`/`complete_schema.sql`.

Estado: pendiente. Se inspeccionó código/documento; todavía no se capturaron respuestas reales ni se ejecutaron pruebas de paridad. Las referencias SQL sin ruta no se presentan como endpoints HTTP existentes. El contrato final debe caracterizar la última definición de cada RPC y sus políticas, no solo la migración inicial.

## Orden, alcance y entrega

Primero se implementa y prueba este backlog en `codigo/salud-u-backend`, independientemente de Next.js. Después se ejecuta el backlog frontend. Ninguna historia backend requiere editar una pantalla para ser aceptada: se valida por HTTP, servicios y PostgreSQL. Prioridades: P0 bloqueante/integridad; P1 obligatorio para completar alcance; P2 recomendado por el documento. Vacunación y datos de investigación se ejecutan al final por dependencia, pero conservan su prioridad documental y no se descartan como opcionales.

Una historia agrupa su caso de uso principal; los escenarios alternativos, errores y permisos se especifican en los criterios. Los casos técnicos usan T-*; los complementarios H-* no reemplazan ni renumeran UC del documento.

## Épica B0 — Base técnica, contratos y estrategia de datos (P0)

### T-01 · Fijar contratos de referencia

**Estado:** referencia local verificada (129 casos pasan; 32 métodos de 24 rutas). Ensayo de integración preparado, pendiente de entorno real según alcance acordado. Evidencia y comandos: [referencia T-01](reference-t01/README.md). No se declara probado SQL/RLS ni paridad desplegada.

- **Actor:** Desarrollador / QA.
- **Historia:** Como Desarrollador / QA, quiero documentar métodos/variantes HTTP, roles, cuerpos, respuestas, errores y efectos de RPC con fixtures sintéticas, para disponer de una base verificable.
- **Caso técnico / comportamiento esperado:** documentar métodos/variantes HTTP, roles, cuerpos, respuestas, errores y efectos de RPC con fixtures sintéticas.
- **Prioridad:** P0. **Dependencias:** —.
- **Aceptación:** Inventariar 24 rutas y todos sus métodos; incluir /api/me con user, reportes con filters, initial-history 410, start 201/200 y data:null; comparar tipos/anidación/orden de arrays/null; caracterizar SQL/RLS vigente; capturar casos con los mismos UUID y reloj o correspondencia explícita de valores generados. Sin credenciales/datos reales en fixtures.
- **Prueba:** ejecutar y registrar resultados automatizados o ensayo reproducible del caso antes de marcar terminado.

### T-02 · Ejecutar plataforma y recuperación

**Estado:** configuración y ensayo automatizado preparados; validaciones estáticas aprobadas. La ejecución completa sigue pendiente porque este equipo no tiene Java, Maven, Docker, Compose ni PostgreSQL. Evidencia: `docs/operations/t02-validation.md`; ensayo: `scripts/verify-platform.sh`.

- **Actor:** Desarrollador / operador.
- **Historia:** Como Desarrollador / operador, quiero compilar y ejecutar Docker, PostgreSQL y repositorio privado con migraciones reproducibles, para disponer de una base verificable.
- **Caso técnico / comportamiento esperado:** compilar y ejecutar Docker, PostgreSQL y repositorio privado con migraciones reproducibles.
- **Prioridad:** P0. **Dependencias:** T-01.
- **Aceptación:** mvn verify y build Docker pasan; health/readiness UP; Flyway base vacía; reinicio conserva volúmenes; respaldo/restauración ensayados; configurar TLS/despliegue y documentar parámetros; no inicializar Git backend ni codigo.
- **Prueba:** ejecutar y registrar resultados automatizados o ensayo reproducible del caso antes de marcar terminado.

### T-03 · Persistencia, contexto de seguridad y auditoría base

**Estado:** diseño e implementación preparados; validación estática aprobada. Prueba de integración Testcontainers y ensayo Docker pendientes de ejecución en una máquina con Docker. Evidencia: `docs/operations/persistence-security.md` y `docs/operations/t03-validation.md`.

- **Actor:** Desarrollador / responsable de seguridad.
- **Historia:** Como Desarrollador / responsable de seguridad, quiero resolver JPA frente a funciones transaccionales, definir RLS y separar usuario migrador/runtime, para disponer de una base verificable.
- **Caso técnico / comportamiento esperado:** resolver JPA frente a funciones transaccionales, definir RLS y separar usuario migrador/runtime.
- **Prioridad:** P0. **Dependencias:** T-02.
- **Aceptación:** Decisión escrita sobre escrituras; sin auth.users/auth.uid/storage; runtime no bypass RLS; actor local a transacción no se filtra entre conexiones; FK/UUID/UTC/JSONB; eventos sensibles append-only; pruebas PostgreSQL y permisos.
- **Prueba:** ejecutar y registrar resultados automatizados o ensayo reproducible del caso antes de marcar terminado.

### T-04 · Publicar API comprobable sin frontend

**Estado:** contratos, OpenAPI, colección Postman y pruebas preparados; validación estática aprobada. `mvn verify`, Testcontainers y Docker están pendientes de una máquina que disponga de Java, Maven y Docker. Evidencia: `docs/operations/api-contracts.md` y `docs/operations/t04-validation.md`.

- **Actor:** Desarrollador / QA.
- **Historia:** Como Desarrollador / QA, quiero establecer DTOs compatibles, errores, OpenAPI y colección Postman por rol, para disponer de una base verificable.
- **Caso técnico / comportamiento esperado:** establecer DTOs compatibles, errores, OpenAPI y colección Postman por rol.
- **Prioridad:** P0. **Dependencias:** T-03.
- **Aceptación:** MockMvc prueba HTTP; Testcontainers prueba PostgreSQL real y concurrencia; sesiones/CSRF verificables desde cliente HTTP; no usuario demo automático; contratos nuevos separados de existentes; resultados/fixtures por historia.
- **Prueba:** ejecutar y registrar resultados automatizados o ensayo reproducible del caso antes de marcar terminado.

## Épica B1 — Identidad, sesión y organización

### BE-01 · UC-01 — Autenticarme y obtener mi identidad y permisos vigentes

**Estado:** implementación y pruebas MockMvc/Testcontainers preparadas; validación estática aprobada. La ejecución de Maven, PostgreSQL y Docker queda pendiente de una máquina que los tenga disponibles. Evidencia: `docs/operations/identity-session.md`, `docs/operations/be01-validation.md` y `docs/fixtures/be-01/identity-session.json`.

- **Actor:** Usuarios internos y estudiante.
- **Historia:** Como Usuarios internos y estudiante, quiero autenticarme y obtener mi identidad y permisos vigentes, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-01: autenticarme y obtener mi identidad y permisos vigentes; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-01; RN-19, RN-28.
- **Prioridad:** P0. **Dependencias:** T-03; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET /api/me; src/app/actions/session.ts; demo-session.ts; Supabase Auth.
- **Criterios de aceptación:**
  - Credenciales válidas crean sesión HttpOnly/SameSite/Secure.
  - sin sesión GET me devuelve 401/unauthenticated.
  - éxito conserva ok/user y sus cinco campos.
  - rol revocado pierde acceso.
  - logout y expiración invalidan sesión.
  - intentos limitados y CSRF probado.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-CAT · Administrar catálogos y organización

**Estado:** implementación y pruebas MockMvc/Testcontainers preparadas; validación estática aprobada. La ejecución contra Maven, Docker y PostgreSQL está pendiente. Evidencia: `docs/operations/catalogs-and-organization.md`, `docs/operations/becat-validation.md` y `docs/fixtures/be-cat/catalogs.json`.

- **Actor:** Administrativo autorizado.
- **Historia y caso complementario:** Como Administrativo autorizado, quiero gestionar roles/personal/especialidades/carreras y catálogos clínicos, para mantener los datos y accesos necesarios.
- **Comportamiento esperado:** gestionar roles/personal/especialidades/carreras y catálogos clínicos.
- **Trazabilidad:** RF-28. **Prioridad:** P1. **Dependencia:** BE-01.
- **Referencia:** GET /api/careers, /api/specialties, /api/my-specialties; escrituras nuevas a especificar.
- **Aceptación:** Catálogos activos/orden/JSON coinciden; médico solo sus especialidades vigentes; escritura solo autorizado; desactivación conserva referencias históricas; diagnósticos/etiquetas/tipos de documento disponibles sin exponer datos clínicos.
- **Prueba:** HTTP por rol y restricciones PostgreSQL; comparación de campos/estados existentes y contrato explícito de extensiones.

### BE-PER · Perfil y contraseña

**Estado:** implementación, contratos y pruebas MockMvc/Testcontainers preparados; validación estática aprobada. La ejecución de Maven, PostgreSQL y Docker queda pendiente de una máquina que los tenga disponibles. Evidencia: `docs/operations/profile-and-password.md`, `docs/operations/beper-validation.md` y `docs/fixtures/be-per/profile-and-password.json`.

- **Actor:** Usuario autenticado.
- **Historia y caso complementario:** Como Usuario autenticado, quiero actualizar nombre/email y cambiar contraseña comprobando la actual, para mantener los datos y accesos necesarios.
- **Comportamiento esperado:** actualizar nombre/email y cambiar contraseña comprobando la actual.
- **Trazabilidad:** RF-01 (complemento observado). **Prioridad:** P1. **Dependencia:** BE-01.
- **Referencia:** src/app/actions/session.ts; Supabase auth.updateUser.
- **Aceptación:** Validación actual y confirmación de email caracterizadas; contraseña incorrecta rechazada; credenciales nuevas funcionan; sesiones revocadas según política documentada; ningún hash/clave en respuesta.
- **Prueba:** HTTP por rol y restricciones PostgreSQL; comparación de campos/estados existentes y contrato explícito de extensiones.

## Épica B2 — Admisión y pacientes

### BE-02 · UC-02 — Registrar, buscar y actualizar un paciente con una historia longitudinal única

**Estado:** implementación, contratos y pruebas MockMvc/Testcontainers preparados; validación estática aprobada. La ejecución de Maven, PostgreSQL y Docker queda pendiente de una máquina que los tenga disponibles. Evidencia: `docs/operations/patients.md`, `docs/operations/be02-validation.md` y `docs/fixtures/be-02/patients.json`.

- **Actor:** Administrativo.
- **Historia:** Como Administrativo, quiero registrar, buscar y actualizar un paciente con una historia longitudinal única, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-02: registrar, buscar y actualizar un paciente con una historia longitudinal única; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-02, RF-03; RN-01, RN-02, RN-19.
- **Prioridad:** P0. **Dependencias:** BE-01,BE-CAT; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET/POST /api/patients; GET/PATCH /api/patients/{id}; rpc_register_or_update_patient.
- **Criterios de aceptación:**
  - POST válido devuelve 201/data.id.
  - PATCH conserva UUID.
  - carnet y registro normalizados duplicados producen 409.
  - búsqueda conserva orden y DTO.
  - inexistente 404.
  - no se crea segunda historia.
  - actor no autorizado no escribe.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

## Épica B3 — Disponibilidad, solicitudes y citas

### BE-04 · UC-04 — Configurar jornadas, bloqueos y cupos publicados para mi disponibilidad

**Estado local actualizado (2026-10-26):** Maven y PostgreSQL ejecutados; 174 pruebas Java aprobadas. El ensayo FE-24 corrige la adaptación de las claves SQL españolas a `schedules/recurringBlocks/dateBlocks/slots` y verifica guardado/recarga real de jornada de especialista mediante Next, junto con `/api/my-specialties` propio vigente. El runtime conserva nombres españoles; no se mueven reglas a Next. Evidencia: `docs/operations/availability.md` y `../salud-u/docs/evidencia-fe24.md`.

- **Actor:** Médico de revisión / especialista.
- **Historia:** Como Médico de revisión / especialista, quiero configurar jornadas, bloqueos y cupos publicados para mi disponibilidad, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-04: configurar jornadas, bloqueos y cupos publicados para mi disponibilidad; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-05; RN-06, RN-07, RN-13.
- **Prioridad:** P0. **Dependencias:** BE-CAT; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET/POST/DELETE /api/availability-slots; rpc_replace_my_availability_schedule, rpc_publish_availability_slot, rpc_create_my_availability_block, rpc_delete_my_availability_block.
- **Criterios de aceptación:**
  - manage=true conserva estructura/orden.
  - bloquear todo el día o parte produce cupos correctos.
  - solapamientos y especialidad inactiva rechazados.
  - reservas existentes no se destruyen.
  - zona America/La_Paz y generación de 90 días contrastadas con SQL vigente.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-05 · UC-05 — Solicitar una revisión y consultar o cancelar mi solicitud pendiente

- **Actor:** Estudiante / Administrativo.
- **Historia:** Como Estudiante / Administrativo, quiero solicitar una revisión y consultar o cancelar mi solicitud pendiente, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-05: solicitar una revisión y consultar o cancelar mi solicitud pendiente; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-06; RN-12, RN-19, RN-25.
- **Prioridad:** P0. **Dependencias:** BE-02; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET/POST /api/appointment-requests; PATCH /api/appointment-requests/{id}; rpc_create_initial_appointment_request, rpc_create_appointment_request_for_patient, rpc_cancel_appointment_request.
- **Criterios de aceptación:**
  - Creación 201/data.id.
  - estudiante solo puede solicitar INITIAL para sí mismo.
  - cancelación válida data:null.
  - listado por actor.
  - solicitudes incompatibles y transiciones inválidas rechazadas sin cambios.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-06 · UC-06 — Crear una solicitud de especialidad directa diferenciada de una derivación

- **Actor:** Administrativo.
- **Historia:** Como Administrativo, quiero crear una solicitud de especialidad directa diferenciada de una derivación, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-06: crear una solicitud de especialidad directa diferenciada de una derivación; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-06; RN-12, RN-19.
- **Prioridad:** P0. **Dependencias:** BE-05,BE-CAT; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** POST /api/appointment-requests; rpc_create_appointment_request_for_patient.
- **Criterios de aceptación:**
  - SPECIALTY exige especialidad activa.
  - no exige derivación de revisión.
  - estudiante no puede crearla.
  - respuesta 201/data.id.
  - procedencia administrativa persistida y compatible con asignación.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-07 · UC-07 — Asignar una solicitud pendiente a un médico y cupo compatibles

- **Actor:** Administrativo.
- **Historia:** Como Administrativo, quiero asignar una solicitud pendiente a un médico y cupo compatibles, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-07: asignar una solicitud pendiente a un médico y cupo compatibles; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-07; RN-06, RN-07, RN-12, RN-25.
- **Prioridad:** P0. **Dependencias:** BE-04,BE-05,BE-06; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** POST /api/appointment-requests/{id}/assign; rpc_assign_appointment_request.
- **Criterios de aceptación:**
  - Respuesta data.appointmentId.
  - cupo futuro publicado y compatible.
  - dos peticiones al último cupo producen una sola reserva.
  - solicitud/cita/capacidad/evento actualizan juntos.
  - paciente sin solapamiento.
  - rollback ante fallo.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-08 · UC-08 — Registrar llegada o ausencia y cancelar en las condiciones permitidas

- **Actor:** Administrativo; estudiante para cancelar su solicitud.
- **Historia:** Como Administrativo; estudiante para cancelar su solicitud, quiero registrar llegada o ausencia y cancelar en las condiciones permitidas, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-08: registrar llegada o ausencia y cancelar en las condiciones permitidas; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-08; RN-07, RN-08, RN-25.
- **Prioridad:** P0. **Dependencias:** BE-07; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** POST /api/appointments/{id}/check-in, /no-show; PATCH /api/appointment-requests/{id}; rpc_check_in_appointment, rpc_mark_appointment_no_show, rpc_cancel_appointment_request.
- **Criterios de aceptación:**
  - Éxito conserva data:null.
  - llegada no cuenta como atención cerrada.
  - repetición/transición inválida no duplica eventos.
  - liberación de capacidad según estado se contrasta con SQL.
  - cancelar una cita se especifica por separado si la referencia solo cancela solicitudes.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

## Épica B4 — Revisión clínica, antecedentes y documentos

### BE-09 · UC-09 — Iniciar o recuperar el encuentro borrador de una cita asignada

- **Actor:** Médico asignado.
- **Historia:** Como Médico asignado, quiero iniciar o recuperar el encuentro borrador de una cita asignada, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-09: iniciar o recuperar el encuentro borrador de una cita asignada; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-09; RN-02, RN-13, RN-25.
- **Prioridad:** P0. **Dependencias:** BE-08; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET /api/medical/appointments; POST /api/medical/appointments/{id}/start; rpc_open_encounter.
- **Criterios de aceptación:**
  - Creación 201 con encounterId/status DRAFT.
  - recuperación 200 con mismo ID/estado.
  - cita ajena 404.
  - estado inválido 409.
  - concurrencia crea un encuentro por cita.
  - lista conserva fechas y orden.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-03 · UC-03 — Consultar y actualizar antecedentes globales con motivo y versiones

- **Actor:** Médico autorizado.
- **Historia:** Como Médico autorizado, quiero consultar y actualizar antecedentes globales con motivo y versiones, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-03: consultar y actualizar antecedentes globales con motivo y versiones; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-04, RF-20; RN-03, RN-04, RN-05, RN-14.
- **Prioridad:** P0. **Dependencias:** BE-09; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET/PATCH /api/medical/patients/{id}/clinical-background; rpc_get_clinical_background, rpc_save_clinical_background.
- **Criterios de aceptación:**
  - Sin antecedentes se solicita registro inicial.
  - cambio exige changeReason.
  - alergias/hábitos/medicación y elementos individuales conservan su forma.
  - actualización crea versión y autor.
  - atención cerrada conserva versión anterior.
  - médico ajeno no accede.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-10 · UC-10 — Completar ficha estructurada, diagnósticos, mediciones e indicaciones de revisión

- **Actor:** Médico de revisión.
- **Historia:** Como Médico de revisión, quiero completar ficha estructurada, diagnósticos, mediciones e indicaciones de revisión, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-10: completar ficha estructurada, diagnósticos, mediciones e indicaciones de revisión; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-10, RF-12; RN-04, RN-05, RN-09, RN-10, RN-16.
- **Prioridad:** P0. **Dependencias:** BE-03; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** POST /api/medical/encounters/{id}/finalize, campo reviewHistory; review-history.ts; rpc_finalize_initial_encounter.
- **Criterios de aceptación:**
  - Campos/listas/null y validaciones se comparan con referencia.
  - antecedentes precargados.
  - ficha ligada al encuentro.
  - modificar ficha cerrada rechazado.
  - definir API de borrador si se requiere guardado servidor, porque la ruta actual persiste ficha al finalizar.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-11 · UC-11 — Adjuntar, clasificar, previsualizar y descargar documentos privados de la atención

**Extensión de integración FE-11 (2026-10-25):** V49 incorpora listado autorizado de metadatos y serialización carga/cierre; descarga revalida acceso y registra auditoría. Se conservan multipart/201/data.id y data.url. Pasan 114 pruebas Java y navegador con 15 MiB, permisos, caducidad real de 60 s y recuperación de sesión/CSRF. [Contrato y evidencia](fe11-documentos-integracion.md).

- **Actor:** Médico autorizado.
- **Historia:** Como Médico autorizado, quiero adjuntar, clasificar, previsualizar y descargar documentos privados de la atención, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-11: adjuntar, clasificar, previsualizar y descargar documentos privados de la atención; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-17; RN-10, RN-17, RN-18, RN-27.
- **Prioridad:** P0. **Dependencias:** BE-09; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** POST /api/medical/documents; GET /api/medical/documents/{id}/download; rpc_create_document_upload, rpc_finalize_document_upload; Storage clinical-documents.
- **Criterios de aceptación:**
  - Multipart válido 201/data.id.
  - PDF/JPG/PNG/WEBP hasta 15 MiB.
  - archivo vacío/otro MIME rechazado.
  - contenido/tamaño/checksum verificados.
  - GET devuelve data.url con vigencia observable 60 s.
  - ajeno y expirado denegados.
  - fallo no publica archivo incompleto.
  - corregir límite inicial backend de 10 MB.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-12 · UC-12 — Cerrar revisión conservando ficha inmutable y cita atendida

**Aceptación desde FE-12 (2026-10-25):** cierre/recarga con cita ATTENDED, JSON RPC exacto, dos pestañas con 200/409 y un solo evento/auditoría, rechazo tardío sin datos parciales y checksum lógico intacto. Backend vigente validado con 114 pruebas; integración sin nueva migración ni cambios en las reglas SQL. [Evidencia frontend](../../salud-u/docs/evidencia-fe12.md).

- **Actor:** Médico de revisión.
- **Historia:** Como Médico de revisión, quiero cerrar revisión conservando ficha inmutable y cita atendida, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-12: cerrar revisión conservando ficha inmutable y cita atendida; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-13; RN-05, RN-08, RN-09, RN-10, RN-25.
- **Prioridad:** P0. **Dependencias:** BE-10,BE-11; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** POST /api/medical/encounters/{id}/finalize; rpc_finalize_initial_encounter.
- **Criterios de aceptación:**
  - Motivo y evaluación obligatorios.
  - ATTACHED exige documento disponible.
  - ficha/diagnósticos/versión/cita ATTENDED/evento en una transacción.
  - error revierte todo.
  - doble cierre no duplica.
  - devolver JSON exacto de RPC caracterizada.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

## Épica B5 — Derivaciones y atención especializada

### BE-13 · UC-13 — Emitir derivación con contexto de revisión, prioridad y elementos compartidos

**Aceptación de integración FE-13 (2026-10-25):** V50 completa lectura propia, contexto recuperable y evento/auditoría de emisión atómica. Se conservan la firma de finalización y los elementos automáticos de referencia. Pasan 118 pruebas Java, con carrera 200/409 y rollback al fallar la derivación después del cierre interno; Chromium verifica tres prioridades, límites de acceso y recarga. [Evidencia frontend](../../salud-u/docs/evidencia-fe13.md).

- **Actor:** Médico de revisión.
- **Historia:** Como Médico de revisión, quiero emitir derivación con contexto de revisión, prioridad y elementos compartidos, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-13: emitir derivación con contexto de revisión, prioridad y elementos compartidos; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-15, RF-16; RN-11, RN-17.
- **Prioridad:** P0. **Dependencias:** BE-12; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** finalize con referralSpecialtyId/reason/comment/priority; rpc_finalize_initial_encounter; rpc_create_referral en SQL.
- **Criterios de aceptación:**
  - Atención origen cerrada.
  - motivo/resumen/especialidad obligatorios.
  - documentos y diagnósticos del mismo paciente.
  - derivación opcional se crea atómicamente con cierre.
  - sin datos no se deriva.
  - profesional ajeno rechazado.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-14 · UC-14 — Programar una derivación activa sin cambiar su contenido clínico

**Verificación de integración FE-14 (2026-10-25):** V51 recupera bandeja/historial y orden de referencia, valida paciente/derivación al crear solicitud y agrega evento/auditoría de asignación en su transacción. Contratos HTTP y permisos documentados en OpenAPI. 124 pruebas Java pasan, incluidas creación/asignación concurrentes, rechazo de derivación cerrada e invariancia del origen. Chromium comprobó la integración administrativa y la regresión de asistencia. [Evidencia frontend y comandos](../../salud-u/docs/evidencia-fe14.md).

- **Actor:** Administrativo.
- **Historia:** Como Administrativo, quiero programar una derivación activa sin cambiar su contenido clínico, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-14: programar una derivación activa sin cambiar su contenido clínico; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-06, RF-07, RF-15; RN-06, RN-07, RN-12.
- **Prioridad:** P0. **Dependencias:** BE-13,BE-07; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET /api/administrative/referrals; GET /api/patients/{id}/referrals; solicitudes REFERRAL y assign; rpc_list_referrals_for_administration, rpc_list_patient_referrals_for_appointment, rpc_assign_appointment_request.
- **Criterios de aceptación:**
  - Bandeja/JSON conservados.
  - solo derivación activa y cupo de especialidad compatible.
  - asignación actualiza estado/cita/cupo juntos.
  - mismo origen intacto.
  - doble asignación y derivación cerrada rechazadas.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-15 · UC-15 — Completar y cerrar ficha del área usando plantilla versionada

**Verificación de integración FE-15 (2026-10-25):** V52 completa persistencia del resumen clínico, consulta de ficha/plantilla histórica, autorización vigente, serialización de versión y archivos compartidos de origen. templateId es una extensión opcional con control de plantilla activa. V53 corrige la ambigüedad de estado al iniciar una atención derivada y registra IN_PROGRESS una sola vez. Pasan 126 pruebas Java y seis grupos de navegador con Next en producción; regresión FE-14 aprobada. [Evidencia y comandos](../../salud-u/docs/evidencia-fe15.md).

- **Actor:** Especialista asignado.
- **Historia:** Como Especialista asignado, quiero completar y cerrar ficha del área usando plantilla versionada, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-15: completar y cerrar ficha del área usando plantilla versionada; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-11, RF-12, RF-13; RN-13, RN-14, RN-15.
- **Prioridad:** P0. **Dependencias:** BE-14,BE-06,BE-09; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** start y finalize para SPECIALTY; rpc_finalize_specialty_encounter; specialty-history.ts.
- **Criterios de aceptación:**
  - Solo especialidad activa propia.
  - contexto de origen accesible si derivado.
  - directa funciona sin ficha origen.
  - plantilla/version asociadas al encuentro.
  - cambio de plantilla no modifica pasado.
  - cierre atómico/JSON de referencia.
  - ficha ajena denegada.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-16 · UC-16 — Resolver o devolver una derivación dejando motivo y seguimiento

**Verificación de integración FE-16 (2026-10-25):** se conserva PATCH /api/medical/referrals/{id} y se documentan GET propios /api/medical/assigned-referrals y /{id}. V54 verifica especialidad/afiliación vigentes y atención cerrada propia; registra resolución/devolución y auditoría en una transacción. Repetición mantiene 403 sin duplicar. Pasan 130 pruebas Java con rollback/carrera PostgreSQL y cinco grupos Chromium en producción; regresión FE-15 aprobada. [Evidencia y comandos](../../salud-u/docs/evidencia-fe16.md).

- **Actor:** Especialista asignado.
- **Historia:** Como Especialista asignado, quiero resolver o devolver una derivación dejando motivo y seguimiento, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-16: resolver o devolver una derivación dejando motivo y seguimiento; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-15; RN-11, RN-13, RN-25.
- **Prioridad:** P0. **Dependencias:** BE-15; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** rpc_close_referral, rpc_assign_referral presentes en SQL; ruta HTTP dedicada no confirmada.
- **Criterios de aceptación:**
  - Resolución/devolución desde estado permitido.
  - motivo de devolución obligatorio.
  - evento/seguimiento/emisor persistidos.
  - especialista ajeno y transición inválida rechazados.
  - repetición no duplica.
  - verificar semántica SQL antes de definir nuevo endpoint.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

## Épica B6 — Historia longitudinal y correcciones

### BE-17 · UC-17 — Consultar la historia longitudinal permitida por mi área

**Verificación de integración FE-17 (2026-10-25):** V55–V57 exigen relación clínica, aplican área/origen remitido, completan antecedentes/versiones/derivaciones y los campos heredados de historia, citas y diagnóstico. Firma/contenido/lista de documentos y búsqueda respetan el mismo ámbito. Historia vacía autorizada 200, sin acceso 404 de referencia; GET auditado y no-store. Pasan 133 pruebas Java, cuatro grupos Chromium en producción y regresión FE-16. [Evidencia y comandos](../../salud-u/docs/evidencia-fe17.md).

- **Actor:** Médico con relación clínica.
- **Historia:** Como Médico con relación clínica, quiero consultar la historia longitudinal permitida por mi área, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-17: consultar la historia longitudinal permitida por mi área; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-03, RF-18; RN-02, RN-05, RN-14, RN-17.
- **Prioridad:** P0. **Dependencias:** BE-15; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET /api/medical/patients/{id}; tablas y políticas RLS.
- **Criterios de aceptación:**
  - Revisión ve revisión.
  - especialista su área y origen remitido autorizado.
  - citas/versiones/diagnósticos/documentos conservan orden y null.
  - paciente sin acceso devuelve estado/mensaje de referencia.
  - administración no recibe contenido clínico.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-18 · UC-18 — Buscar por fechas y contenido dentro de la historia autorizada

**Verificación de integración FE-18 (2026-10-25):** V58/V59 completan normalización, fechas inclusivas America/La_Paz, contenido de fichas/diagnósticos/documentos vinculados e índices. GET /api/medical/patients/{id}/search conserva null mediante resultado tipado, audita sin término clínico y aplica la autorización FE-17. Pasan 136 pruebas Java y navegador/regresión. Perfil sintético: 1.001 atenciones, 20 consultas con concurrencia 10, p95 local menor de 3 s. El usuario describe un centro pequeño con picos y reportes de fin de mes; el volumen numérico y la carga mixta quedan para el corte integral. [Evidencia y comandos](../../salud-u/docs/evidencia-fe18.md).

- **Actor:** Médico con relación clínica.
- **Historia:** Como Médico con relación clínica, quiero buscar por fechas y contenido dentro de la historia autorizada, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-18: buscar por fechas y contenido dentro de la historia autorizada; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-19; RN-14, RN-20.
- **Prioridad:** P1. **Dependencias:** BE-17; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** ficha médica y filtros de UI; endpoint servidor de búsqueda por definir si no existe.
- **Criterios de aceptación:**
  - Coincidencia parcial normalizada y rango válidos.
  - no busca/devuelve contenido de otras áreas.
  - resultados coherentes con línea de tiempo.
  - sin coincidencias lista vacía.
  - búsqueda común menor a 3 s con volumen institucional acordado.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-19 · UC-19 — Añadir una corrección auditable sin reescribir la atención cerrada

**Verificación de integración FE-19 (2026-10-25):** POST confirmado y conservado como 200/data(id,amendmentNo,createdAt,createdBy); GET nuevo con canAdd/items documentado. V60 aplica autorización FE-17, escritura solo del autor, auditoría atómica, numeración serializada y clave opcional de reintento, preservando la firma SQL de tres argumentos. Tabla sin DML runtime y trigger contra UPDATE/DELETE; lectura y búsqueda autorizadas. Pasan 140 pruebas Java con concurrencia/rollback/inmutabilidad y cinco grupos Chromium en producción; regresión FE-18 aprobada. [Evidencia y comandos](../../salud-u/docs/evidencia-fe19.md).

- **Actor:** Médico autorizado.
- **Historia:** Como Médico autorizado, quiero añadir una corrección auditable sin reescribir la atención cerrada, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-19: añadir una corrección auditable sin reescribir la atención cerrada; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-14; RN-09, RN-26, RN-27.
- **Prioridad:** P2. **Dependencias:** BE-17; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** rpc_add_encounter_amendment en SQL; ruta HTTP dedicada no confirmada.
- **Criterios de aceptación:**
  - Atención cerrada y motivo/contenido obligatorios.
  - original/checksum lógico intacto.
  - adenda con actor/fecha y lectura autorizada.
  - ajeno rechazado.
  - no eliminación física.
  - caracterizar RPC y definir contrato nuevo si hace falta.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-20 · UC-20 — Exportar una ficha individual a Word

**Verificación de integración FE-20 (2026-10-26):** GET `/api/medical/encounters/{id}/export.docx` confirmado/documentado; V61 amplía el snapshot autorizado a ficha/versiones/plantilla/antecedentes vinculados/diagnósticos/mediciones/documentos y adendas ordenadas. DOCX con emblemas, fecha Bolivia, autor y secciones separadas; finalidad y procedencia auditadas tras generación, sin publicación parcial ante fallo. Rechazo uniforme 404 fuera del ámbito/no cerrado; errores internos 500 recuperables. Pasan 147 pruebas Java, cuatro grupos Chromium y regresión FE-19. Siete DOCX reabiertos en LibreOffice y clínica intacta. [Evidencia y comandos](../../salud-u/docs/evidencia-fe20.md).

- **Actor:** Médico autorizado.
- **Historia:** Como Médico autorizado, quiero exportar una ficha individual a Word, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-20: exportar una ficha individual a Word; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-21; RN-14, RN-23, RN-26.
- **Prioridad:** P2. **Dependencias:** BE-17; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** src/lib/clinical-word-export.ts y generación docx actual; descarga backend a definir.
- **Criterios de aceptación:**
  - DOCX abre correctamente y conserva contenido/identidad institucional de ficha autorizada.
  - versión correcta, sin datos de otras áreas.
  - registra actor/finalidad cuando corresponda.
  - comparar contenido, no bytes ZIP o fecha generada.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

## Épica B7 — Reportes, cumplimiento y auditoría

### BE-21 · UC-21 — Construir reporte por período, múltiples filtros, columnas y agrupaciones

**Verificación de integración FE-21 (2026-10-26):** V62 completa paridad de listas/antecedentes/hábitos/17 columnas efectivas, ámbito institucional Reportes sin personal y médico propio/área vigente. Conserva firma SQL de 13 columnas; normalización literal y fallback seguro documentados. GET conserva ok/data/filters y agrega presentation opcional con columnas/grupos/IDs/orden explícitos. Auditado sin texto clínico; roles y fechas Bolivia verificados. POST compatible de registro conserva 201/data.id persistido y límites, sin declarar integración del archivo FE-22. Pasan 155 pruebas Java, cuatro grupos Chromium, regresión FE-20 y controles frontend. [Evidencia y comandos](../../salud-u/docs/evidencia-fe21.md).

- **Actor:** Médico / responsable de Reportes.
- **Historia:** Como Médico / responsable de Reportes, quiero construir reporte por período, múltiples filtros, columnas y agrupaciones, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-21: construir reporte por período, múltiples filtros, columnas y agrupaciones; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-22, RF-23, RF-33; RN-20, RN-21, RN-23.
- **Prioridad:** P1. **Dependencias:** BE-17; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET /api/reports/clinical; rpc_clinical_report; clinical-report-builder.ts.
- **Criterios de aceptación:**
  - JSON conserva ok/data/filters.
  - combinación de listas/texto normalizado/rangos devuelve mismas filas/orden de referencia.
  - cero resultados [] y período inválido 400.
  - ámbito médico restringido.
  - columnas/agrupaciones documentales adicionales se prueban con contrato explícito.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-22 · UC-22 — Exportar el conjunto permitido en CSV/XLSX/PDF con finalidad

**Verificación de integración FE-22 (2026-10-26):** endpoint separado de archivo completo/documentado, con REPORTING_OFFICER y ámbito de FE-21; rechaza filas/cantidad del cliente y limita a 10000 sin truncar. CSV/XLSX/PDF comparten datos/columnas/grupos/metadatos; PDF real paginado, Excel reabierto con POI/SheetJS, protección de fórmulas y continuación de texto extenso. V63 guarda procedencia propia COMPLETED/FAILED con SHA-256 y auditoría atómica, sin publicar parciales. POST compatible conserva 201/data.id y límites 0..10000. Pasan 167 pruebas Java, cuatro grupos Chromium y regresión FE-21; clínica original intacta y recuperación real de sesión comprobada. [Evidencia, alcance tipográfico y comandos](../../salud-u/docs/evidencia-fe22.md).

- **Actor:** Usuario autorizado para exportar.
- **Historia:** Como Usuario autorizado para exportar, quiero exportar el conjunto permitido en CSV/XLSX/PDF con finalidad, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-22: exportar el conjunto permitido en CSV/XLSX/PDF con finalidad; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-24; RN-21, RN-22, RN-23, RN-26.
- **Prioridad:** P1. **Dependencias:** BE-21; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** POST /api/reports/clinical; rpc_log_clinical_report_export; xlsx/jspdf frontend; rpc_request_report_export SQL.
- **Criterios de aceptación:**
  - POST actual conserva 201/data.id y validación 0..10000 filas.
  - nuevo endpoint de archivo separado y documentado.
  - backend recalcula filas autorizadas.
  - finalidad/filtros/formato/estado/cantidad auditados.
  - CSV/XLSX/PDF equivalentes en contenido y estilo requerido.
  - fallo no publica incompleto.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-23 · UC-23 — Consultar cumplimiento institucional de atención obligatoria

**Verificación de integración FE-23 (2026-10-26):** V64 usa días Bolivia en cumplimiento/actividad y agrega resumen administrativo de conteos, sin texto clínico. Se conservan contratos de listas y se audita lectura con no-store/private; fallos de infraestructura 500 recuperables. Cierres múltiples no duplican matrícula; llegada/ausencia/borrador y cierres fuera de ventana no cumplen. Pasan 169 pruebas Java, cuatro grupos Chromium y regresión FE-22. Regla y volumen institucionales aún pendientes de validación formal en FE-CORTE. [Evidencia y comandos](../../salud-u/docs/evidencia-fe23.md).

- **Actor:** Administrativo / Reportes.
- **Historia:** Como Administrativo / Reportes, quiero consultar cumplimiento institucional de atención obligatoria, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-23: consultar cumplimiento institucional de atención obligatoria; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-25; RN-08, RN-24.
- **Prioridad:** P1. **Dependencias:** BE-12,BE-21; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** rpc_compliance_report, rpc_daily_activity; src/app/administrativo/page.tsx y reportes/cumplimiento/page.tsx.
- **Criterios de aceptación:**
  - Solo atención cerrada dentro de regla académica vigente computa.
  - check-in/ausencia no cumplen.
  - agregados y pendientes equivalentes con misma semilla.
  - filtros carrera/período y permisos.
  - regla académica y volumen validados con institución.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-24 · UC-24 — Consultar eventos de accesos, cambios y exportaciones sin modificar evidencia

**Integración FE-24 verificada (2026-10-26):** GET `/api/audit-events` real, solo autoridad Auditor. V65 agrega actor parcial, cursor por fecha/UUID y días de Bolivia conservando la firma SQL y respuesta compatible; OpenAPI actualizado. Runtime sin UPDATE/DELETE, sin endpoint de mutación; lecturas auditadas sin metadata clínica. 174 pruebas Java aprobadas y cinco grupos de aceptación Chromium con Next/Spring/PostgreSQL; regresión FE-23 completa. Evidencia: `../salud-u/docs/evidencia-fe24.md`.

- **Actor:** Auditor.
- **Historia:** Como Auditor, quiero consultar eventos de accesos, cambios y exportaciones sin modificar evidencia, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-24: consultar eventos de accesos, cambios y exportaciones sin modificar evidencia; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-26, RF-27; RN-26, RN-28.
- **Prioridad:** P1. **Dependencias:** BE-01,T-03; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** GET `/api/audit-events` real en Spring y SQL de consulta protegida. El frontend retira `demo-audit-store.ts`; V65 agrega filtros y paginación documentados.
- **Criterios de aceptación:**
  - Filtros fecha/actor/acción/recurso/resultado.
  - solo Auditor consulta.
  - tablas append-only, no edición/borrado runtime.
  - operaciones sensibles previas generan eventos sin texto clínico/contraseñas/tokens.
  - actor correcto aun con pool de conexiones.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

## Épica B8 — Vacunación e investigación

### BE-25 · UC-25 — Gestionar vacunas activas y sus dosis/intervalos

**Integración FE-25 verificada (2026-10-26):** `/api/vaccines` GET/POST/PUT en uso desde `/administrativo/vacunas`. V66 agrega `guardar_vacuna_y_esquema(..., p_version_esperada)` con bloqueo de fila: `expectedSchemaVersion` desactualizada → 409 sin nueva versión; código duplicado → 409; vacuna inexistente → 404 (antes todo era 400). Firma de cinco argumentos conservada; OpenAPI y pruebas MVC/PostgreSQL actualizadas. 176 pruebas Java aprobadas y seis grupos Chromium. Evidencia: `../salud-u/docs/evidencia-fe25.md`.

- **Actor:** Administrativo.
- **Historia:** Como Administrativo, quiero gestionar vacunas activas y sus dosis/intervalos, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-25: gestionar vacunas activas y sus dosis/intervalos; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-29; RN-29, RN-30.
- **Prioridad:** P1. **Dependencias:** BE-CAT; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** Documento incremento 6; endpoint/RPC productivos no confirmados.
- **Criterios de aceptación:**
  - Crear/actualizar/desactivar catálogo y esquema válido.
  - desactivar no elimina dosis históricas.
  - número/intervalo inválidos rechazados.
  - roles sin permiso no escriben.
  - contrato nuevo OpenAPI y pruebas de integración.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-26 · UC-26 — Registrar dosis aplicada conservando lote, fecha y responsables

**Integración FE-26 verificada (2026-10-26):** V67 agrega `contexto_registro_vacunacion` (GET `/api/vaccinations/context`, auditado como `VACCINATION_RECORD_READ`) y reemplaza `registrar_dosis_vacuna` con la misma firma: el Médico de revisión requiere `requerir_acceso_medico_paciente` y la fecha futura se evalúa en día de Bolivia. Rechazos distinguibles: 422 intervalo sin justificación; 409 duplicado/orden/vacuna inactiva; 400 fechas, aplicador o justificación; 403 rol/aplicador ajeno; 404 paciente inexistente o ajeno. OpenAPI y pruebas MVC/PostgreSQL actualizadas. 179 pruebas Java y siete grupos Chromium. Evidencia: `../salud-u/docs/evidencia-fe26.md`.

- **Actor:** Administrativo; médico de revisión como aplicador.
- **Historia:** Como Administrativo; médico de revisión como aplicador, quiero registrar dosis aplicada conservando lote, fecha y responsables, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-26: registrar dosis aplicada conservando lote, fecha y responsables; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-30; RN-29, RN-30, RN-31.
- **Prioridad:** P1. **Dependencias:** BE-25,BE-02; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** Documento incremento 6; endpoint/RPC productivos no confirmados.
- **Criterios de aceptación:**
  - Una dosis por paciente/vacuna/número.
  - vacuna activa y aplicador médico de revisión activo.
  - orden de dosis.
  - intervalo insuficiente advierte y permite solo con justificación.
  - registrador/aplicador distintos campos.
  - duplicado concurrente rechazado.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-27 · UC-27 — Consultar carnet, estado de esquema y cobertura institucional

**Integración FE-27 verificada (2026-10-26):** V68 reemplaza `obtener_carnet_vacunacion` y `reporte_cobertura_vacunacion` con las mismas firmas: carnet con lote/aplicador, vacunas desactivadas solo si hay dosis, Administración sin paciente → 400 y lectura auditada `VACCINATION_CARD_READ`; cobertura con día de Bolivia, `count(DISTINCT)` por grupo y auditoría `VACCINATION_COVERAGE_READ`. Controladores sin `readOnly` por la auditoría; OpenAPI y pruebas MVC/PostgreSQL actualizadas. 180 pruebas Java y seis grupos Chromium. Evidencia: `../salud-u/docs/evidencia-fe27.md`.

- **Actor:** Administrativo / Estudiante / Reportes.
- **Historia:** Como Administrativo / Estudiante / Reportes, quiero consultar carnet, estado de esquema y cobertura institucional, para completar el flujo con integridad y acceso autorizado.
- **Caso de uso / comportamiento esperado:** UC-27: consultar carnet, estado de esquema y cobertura institucional; ejecutar reglas en Spring/PostgreSQL y persistir únicamente cambios autorizados.
- **Trazabilidad:** RF-31, RF-32; RN-21, RN-29, RN-30.
- **Prioridad:** P2. **Dependencias:** BE-26; T-04 para pruebas HTTP.
- **Referencia actual (ruta/RPC/consumidor):** Documento incremento 6; endpoint/RPC productivos no confirmados.
- **Criterios de aceptación:**
  - Estudiante solo carnet propio.
  - estado calculado con esquema/dosis.
  - cobertura por vacuna/carrera/gestión sin duplicados.
  - reportes restringidos.
  - cambios de catálogo conservan procedencia histórica.
  - límites acceso probados.
  - Dado un actor autorizado y datos válidos, la operación devuelve el contrato caracterizado; dado un actor ajeno o datos inválidos, se rechaza sin cambios parciales ni exposición clínica.
- **Pruebas:** contrato HTTP éxito/error; permisos por actor; integración PostgreSQL de persistencia/transacción; casos de concurrencia y versión indicados arriba. Comparar con fixtures de T-01 donde exista referencia actual.

### BE-INV · H-INV — Exportación para investigación

**Integración FE-INV verificada (2026-10-26):** V69 valida filtros con `filtros_investigacion_normalizados` (sólo `from`, `to`, `careerId`, `specialtyId`, `vaccineId`; `400` ante clave, fecha o UUID inválidos), calcula mes de atención, edad, matrícula y mes de política en día de Bolivia, registra mes de política y SHA-256 y audita finalidad y nombres de filtros. El controlador responde `X-Export-Id`, `X-Export-Row-Count`, `X-Content-SHA256` y `X-Pseudonym-Policy`, aplica el límite con `limit 10001`, escribe CSV con BOM y fórmulas neutralizadas, XLSX con conteos numéricos y diccionario en español; nuevo `GET /api/research/exports/{id}` sólo para el solicitante (otro → `404`). `listar_vacunas`/`GET /api/vaccines` pasan a lectura para Reportes (escritura sigue sólo Administración). Política de vinculación: `MONTHLY-V1` (ver `docs/politica-seudonimos-investigacion.md`). Pruebas MVC/PostgreSQL y OpenAPI actualizadas.

- **Actor:** Reportes / usuario autorizado para investigación.
- **Historia:** Como usuario autorizado, quiero exportar un conjunto seudonimizado con diccionario, para investigar sin revelar identidad estudiantil.
- **Comportamiento esperado:** construir conjunto autorizado, transformar identificadores y registrar finalidad/procedencia sin exigir aprobación previa según RN-32.
- **Trazabilidad:** RF-34; RN-22, RN-23, RN-32. **Prioridad:** P1. **Dependencias:** BE-21, BE-22; BE-27 para incluir vacunación.
- **Referencia:** documento; contratos actuales de reporte/exportación no acreditan esta funcionalidad completa. Endpoint nuevo a especificar.
- **Aceptación:** ningún carnet/registro/nombre en conjunto; edad en rangos y fechas al mes; diccionario coherente; seudónimo conforme a política documentada; solicitante/finalidad/filtros/formato/filas registrados; rol ajeno rechazado; exportaciones repetidas respetan política de vinculación definida.
- **Prueba:** inspección automatizada de columnas/valores para detectar identificadores; permisos; auditoría y descarga íntegra.

## Épica B9 — Paridad, migración y aceptación integral (P0)

### BE-CORTE · H-CORTE — Backend listo para integrar

- **Actor:** Desarrollador / QA / operador institucional.
- **Historia:** Como equipo técnico, quiero demostrar el flujo completo por API y ensayar la migración, para entregar un backend comprobado al frontend.
- **Comportamiento esperado:** ejecutar login → paciente → disponibilidad → solicitud → asignación → llegada → revisión → derivación → especialidad → historia → reporte; vacunas/investigación en su incremento.
- **Dependencias:** historias anteriores según alcance de entrega; ninguna historia requerida se omite sin decisión explícita de alcance.
- **Aceptación:** suite independiente de Next pasa; RF-01–34 y UC-01–27 trazados; tiempos comunes <3 s con volumen institucional acordado; migración conserva UUID/FK/versiones/recuentos/checksum; usuarios/contraseñas tienen estrategia ensayada; backup y rollback probados; diferencias contractuales justificadas. No cambiar datos reales en este ensayo.
- **Prueba:** regresión API por roles; concurrencia; accesos entre áreas; restauración y comparación de datos/archivos. Adjuntar informe y comandos ejecutados.

## Definición de terminado del backend

Migración Flyway + dominio/servicio + transacción + DTO/controlador + permisos por rol/relación/área + auditoría aplicable + OpenAPI/colección + pruebas HTTP/PostgreSQL + evidencia de aceptación. Ninguna pantalla es requisito de cierre. Para comportamiento existente, igualdad de HTTP/JSON/efectos, no solo formato; para funciones nuevas, aceptación contra el documento. Archivos/enlaces se comparan por contenido, permisos y vigencia, no por bytes o tokens variables.

RF-27 es transversal a T-03 y cada historia clínica. RNF-01–05 y 11 se aplican desde base y cada módulo; RNF-06 se verifica en búsquedas/reportes y BE-CORTE; RNF-12 en T-02/BE-CORTE. RNF-07–10 requieren además validación de frontend y no se declaran cumplidos con pruebas de backend solamente.

## Matriz de cobertura

- UC-01 → BE-01 → RF-01.
- UC-02 → BE-02 → RF-02, RF-03.
- UC-04 → BE-04 → RF-05.
- UC-05 → BE-05 → RF-06.
- UC-06 → BE-06 → RF-06.
- UC-07 → BE-07 → RF-07.
- UC-08 → BE-08 → RF-08.
- UC-09 → BE-09 → RF-09.
- UC-03 → BE-03 → RF-04, RF-20.
- UC-10 → BE-10 → RF-10, RF-12.
- UC-11 → BE-11 → RF-17.
- UC-12 → BE-12 → RF-13.
- UC-13 → BE-13 → RF-15, RF-16.
- UC-14 → BE-14 → RF-06, RF-07, RF-15.
- UC-15 → BE-15 → RF-11, RF-12, RF-13.
- UC-16 → BE-16 → RF-15.
- UC-17 → BE-17 → RF-03, RF-18.
- UC-18 → BE-18 → RF-19.
- UC-19 → BE-19 → RF-14.
- UC-20 → BE-20 → RF-21.
- UC-21 → BE-21 → RF-22, RF-23, RF-33.
- UC-22 → BE-22 → RF-24.
- UC-23 → BE-23 → RF-25.
- UC-24 → BE-24 → RF-26, RF-27.
- UC-25 → BE-25 → RF-29.
- UC-26 → BE-26 → RF-30.
- UC-27 → BE-27 → RF-31, RF-32.
- RF-28 → BE-CAT; RF-34 → BE-INV; RF-27 → T-03, BE-24 y autorización de todos los casos.

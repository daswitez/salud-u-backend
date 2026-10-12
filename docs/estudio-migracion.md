# Estudio inicial y migración

Fuente: `Proyecto Daniel Mercado v2 db.md`, revisado en sus requisitos, arquitectura, modelo de datos, seguridad y planificación de incrementos. Secciones clave: 3.2, 3.3.1–3.3.4 y 3.4. Las imágenes embebidas del documento no se interpretaron; el estudio utiliza el texto y los cuadros.

## Arquitectura de destino

Next.js conserva presentación e interacción. Spring Boot concentra autenticación, autorización, transacciones, reportes y acceso a archivos. PostgreSQL conserva restricciones, JSONB, versiones y trazabilidad. El monolito agrupa identidad/organización, pacientes, agenda, revisión, especialidades, derivaciones, documentos y gobierno de datos. Vacunación corresponde al incremento 6.

Se distinguen solicitud, cupo, cita y atención. Una historia longitudinal agrupa versiones por encuentro; el cierre es inmutable y las correcciones generan adendas. La reserva exige control de concurrencia y el cierre con derivación exige atomicidad. Documentos privados tienen metadatos, checksum y descarga temporal autorizada. Roles, especialidad y relación clínica se validan en backend; RLS requiere contexto de actor propio, ya sin auth.uid().

El documento declara 51 tablas, 13 enumerados y 119 claves foráneas; estas cifras son especificaciones a contrastar al migrar, no un esquema implementado por esta base. Hay una decisión técnica por resolver: el documento exige escrituras solo mediante funciones transaccionales y también JPA. Antes de construir repositorios debemos acordar qué escrituras ejecutan funciones y cómo separar el usuario de migraciones del usuario de aplicación y aplicar RLS sin un rol que lo omita.

## Frontend actual

Repositorio en `codigo/salud-u`, rama `backend`, con Next.js 16, React 19, TypeScript y Tailwind 4. Hay 24 archivos de rutas API. `src/lib/api/client.ts` usa URLs de mismo origen, credenciales same-origin y respuesta `{ok,data}` / `{ok:false,error,code?}`. Los contratos exponen campos camelCase y estados en inglés; conviene preservarlos inicialmente con DTOs aunque el documento nombre entidades en español.

`src/lib/supabase/server.ts` crea clientes por cookies y un cliente privilegiado con clave de servidor. `src/proxy.ts` refresca claims. `src/lib/demo-session.ts`, pese a su nombre, obtiene usuarios reales con Supabase Auth y roles desde profile/profile_role. `src/lib/api/route-auth.ts` aplica permisos de rol en las rutas. Existen archivos demo y mock que deben clasificarse antes de retirarlos.

La lógica opera mediante consultas y RPC de Supabase. Los documentos usan el bucket clinical-documents y URLs firmadas por 60 segundos. Las exportaciones frontend incluyen docx, jspdf y xlsx; el destino documental sitúa generación y auditoría en backend. El SQL actual referencia auth.users y APIs de Supabase: no puede cargarse directamente en PostgreSQL independiente.

## Orden de trabajo

1. Identidad, sesiones, permisos y pacientes: sustituir Supabase Auth y perfil técnico, definir CSRF y conexión Next–Spring. Preservar UUID de pacientes y referencias al migrar; las contraseñas requieren estrategia explícita, no copiar usuarios sin validación.
2. Agenda: jornadas, bloqueos, cupos, solicitudes y estados; reserva con bloqueo y prueba de concurrencia.
3. Revisión y documentos: antecedentes globales versionados, ficha por atención, cierre y repositorio privado.
4. Especialidades y derivaciones: contexto de origen y acceso por área/relación clínica.
5. Reportes, exportación y auditoría: POI/OpenPDF, finalidad y permisos.
6. Vacunación y datos para investigación: anonimización/seudonimización y constructor de reportes.

La conexión futura puede conservar `/api` mediante proxy/reenvío hacia Spring en desarrollo y despliegue. Un acceso directo a otro origen exige adaptar credentials, CORS, cookies y CSRF; no basta cambiar la URL. La base actual no altera el frontend ni copia datos, SQL o credenciales de Supabase.

## Inventario de rutas actuales

- `/api/administrative/referrals`
- `/api/appointment-requests/[requestId]/assign`
- `/api/appointment-requests/[requestId]`
- `/api/appointment-requests`
- `/api/appointments/[appointmentId]/check-in`
- `/api/appointments/[appointmentId]/no-show`
- `/api/availability-slots`
- `/api/careers`
- `/api/health/supabase`
- `/api/me`
- `/api/medical/appointments/[appointmentId]/start`
- `/api/medical/appointments`
- `/api/medical/documents/[documentId]/download`
- `/api/medical/documents`
- `/api/medical/encounters/[encounterId]/finalize`
- `/api/medical/patients/[patientId]/clinical-background`
- `/api/medical/patients/[patientId]`
- `/api/my-specialties`
- `/api/patients/[patientId]/initial-history`
- `/api/patients/[patientId]/referrals`
- `/api/patients/[patientId]`
- `/api/patients`
- `/api/reports/clinical`
- `/api/specialties`

## RPC utilizadas por las rutas

- `rpc_assign_appointment_request`
- `rpc_cancel_appointment_request`
- `rpc_check_in_appointment`
- `rpc_clinical_report`
- `rpc_create_appointment_request_for_patient`
- `rpc_create_document_upload`
- `rpc_create_initial_appointment_request`
- `rpc_create_my_availability_block`
- `rpc_delete_my_availability_block`
- `rpc_finalize_document_upload`
- `rpc_finalize_initial_encounter`
- `rpc_finalize_specialty_encounter`
- `rpc_get_clinical_background`
- `rpc_list_patient_referrals_for_appointment`
- `rpc_list_referrals_for_administration`
- `rpc_log_clinical_report_export`
- `rpc_mark_appointment_no_show`
- `rpc_open_encounter`
- `rpc_publish_availability_slot`
- `rpc_register_or_update_patient`
- `rpc_replace_my_availability_schedule`
- `rpc_save_clinical_background`

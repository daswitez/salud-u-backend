# Contratos y efectos SQL/RLS vigentes en el repositorio

La fuente es la secuencia de migraciones ordenada por nombre, no una introspección de la instancia desplegada. `rpc-index.json` preserva firma, parámetros/defaults, retorno/seguridad, cuerpo exacto, llamadas auxiliares, excepciones/SQLSTATE, bloqueos y escrituras directas. Las escrituras indirectas de helpers/triggers deben leerse también; el índice no afirma que las tablas listadas sean todos los efectos. `rls/policies.json` resuelve DROP/CREATE literales; `security-events.json` conserva GRANT/REVOKE y RLS. DO dinámicos se preservan en sources; no se simulan en el extractor.

| RPC consumida | Fuente final | Retorno | Tablas escritas directamente | SQLSTATE |
| --- | --- | --- | --- | --- |
| `public.rpc_assign_appointment_request(uuid,uuid)` | supabase/migrations/20260920150100_direct_specialty_and_specialty_history.sql:141 | `returns uuid` | public.appointment, public.appointment_request, public.appointment_status_event, public.availability_slot, public.referral, public.referral_status_event | 23505, 23514, 42501, P0001 |
| `public.rpc_cancel_appointment_request(uuid,text)` | supabase/migrations/20260918160000_admission_and_appointment_requests.sql:136 | `returns void` | public.appointment, public.appointment_request, public.appointment_status_event, public.availability_slot | 23514, 42501, P0002 |
| `public.rpc_check_in_appointment(uuid)` | supabase/migrations/20260918150000_initial_clinical_schema.sql:466 | `returns void` | public.appointment, public.appointment_status_event | 23514, 42501 |
| `public.rpc_clinical_report(jsonb)` | supabase/migrations/20261007100000_multi_criteria_clinical_reports.sql:5 | `returns table(encounter_id uuid,closed_at timestamptz,encounter_type public.encounter_type_code,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,background_summary text,habits jsonb,specialty_history jsonb) language sql stable security definer set search_path=''` | solo lectura | ver helpers |
| `public.rpc_compliance_report(uuid)` | supabase/migrations/20260918150000_initial_clinical_schema.sql:723 | `returns table(patient_id uuid,carnet text,full_name text,career_name text,first_closed_encounter_at timestamptz,compliance_status text) language sql stable security definer set search_path = ''` | solo lectura | ver helpers |
| `public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid,uuid)` | supabase/migrations/20260920150100_direct_specialty_and_specialty_history.sql:119 | `returns uuid` | public.appointment_request | 22023, 23505, 23514, 42501, P0002 |
| `public.rpc_create_document_upload(uuid,uuid,text,text,text,date,text)` | supabase/migrations/20260918150000_initial_clinical_schema.sql:530 | `returns table(document_id uuid,object_path text)` | public.clinical_document | 22023, 42501 |
| `public.rpc_create_initial_appointment_request()` | supabase/migrations/20260918160000_admission_and_appointment_requests.sql:47 | `returns uuid` | public.appointment_request | 23505, 42501, P0002 |
| `public.rpc_create_my_availability_block(date,time,time,text)` | supabase/migrations/20260920130000_recurring_availability.sql:208 | `returns uuid` | public.availability_block, public.availability_slot | 22023, 23505, 42501, P0002 |
| `public.rpc_daily_activity(date,date)` | supabase/migrations/20260918150000_initial_clinical_schema.sql:713 | `returns table(activity_day date,encounter_type public.encounter_type_code,specialty_name text,total_closed bigint) language sql stable security definer set search_path = ''` | solo lectura | ver helpers |
| `public.rpc_delete_my_availability_block(uuid)` | supabase/migrations/20260920130000_recurring_availability.sql:244 | `returns void` | public.availability_block, public.availability_slot | 23514, P0002 |
| `public.rpc_finalize_document_upload(uuid)` | supabase/migrations/20260918150000_initial_clinical_schema.sql:548 | `returns void` | public.clinical_document | 22023, 42501, P0002 |
| `public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code,jsonb)` | supabase/migrations/20260921100000_review_history_versions.sql:57 | `returns jsonb` | public.appointment, public.appointment_status_event, public.clinical_encounter, public.clinical_measurement, public.encounter_diagnosis, public.referral, public.referral_diagnosis, public.referral_document, public.referral_status_event, public.review_history_version | 22023, 23514, 42501 |
| `public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text,jsonb)` | supabase/migrations/20260930190000_atomic_specialty_history_finalize.sql:7 | `returns void` | public.appointment, public.appointment_status_event, public.clinical_encounter, public.encounter_diagnosis, public.referral, public.referral_status_event, public.specialty_history_intake_version | 22023, 23505, 23514, 42501 |
| `public.rpc_get_clinical_background(uuid,uuid)` | supabase/migrations/20261006100000_global_clinical_background.sql:110 | `returns jsonb` | solo lectura | 42501, P0002 |
| `public.rpc_list_patient_referrals_for_appointment(uuid)` | supabase/migrations/20260920140000_administrative_referral_appointments.sql:31 | `returns table(id uuid, specialty_id uuid, specialty_name text, status public.referral_status_code) language sql stable security definer set search_path = ''` | solo lectura | ver helpers |
| `public.rpc_list_referrals_for_administration()` | supabase/migrations/20260920150200_administrative_referral_inbox.sql:3 | `returns table(   id uuid, patient_id uuid, patient_name text, patient_carnet text, specialty_id uuid, specialty_name text,   priority public.referral_priority_code, reason text, comment_for_specialist text, status public.referral_status_code,   requested_at timestamptz, requested_by_name text, assigned_staff_name text, appointment_id uuid, scheduled_for timestamptz )` | solo lectura | ver helpers |
| `public.rpc_log_clinical_report_export(jsonb,text,integer,text)` | supabase/migrations/20260930200000_flexible_clinical_reports.sql:34 | `returns uuid` | public.report_export | 22023, 42501 |
| `public.rpc_mark_appointment_no_show(uuid,text)` | supabase/migrations/20260918160000_admission_and_appointment_requests.sql:158 | `returns void` | public.appointment, public.appointment_status_event | 23514, 42501 |
| `public.rpc_open_encounter(uuid,uuid,uuid,text)` | supabase/migrations/20261006100000_global_clinical_background.sql:195 | `returns uuid` | public.clinical_encounter, public.referral, public.referral_status_event, public.specialty_clinical_history | 23514, 42501 |
| `public.rpc_publish_availability_slot(timestamptz,timestamptz,integer,uuid)` | supabase/migrations/20260918160000_admission_and_appointment_requests.sql:70 | `returns uuid` | public.availability_slot | 22023, 23505, 23514, 42501, P0002 |
| `public.rpc_register_or_update_patient(uuid,text,text,text,text,date,text,text,uuid,uuid,text,date)` | supabase/migrations/20260918150000_initial_clinical_schema.sql:684 | `returns uuid` | public.academic_enrollment, public.clinical_history, public.patient | 42501, P0002 |
| `public.rpc_replace_my_availability_schedule(jsonb,jsonb)` | supabase/migrations/20260920130000_recurring_availability.sql:129 | `returns integer` | public.availability_recurring_block, public.availability_schedule, public.availability_slot | 22023, 23505, 23514, 42501, P0002 |
| `public.rpc_save_clinical_background(uuid,jsonb,integer,uuid,text)` | supabase/migrations/20261006110000_listed_clinical_background_items.sql:6 | `returns jsonb` | public.clinical_background_version, public.clinical_encounter, public.clinical_history | 22023, 40001, 42501, P0002 |

## Reglas caracterizadas y puntos para probar en base real

- Registro: `rpc_register_or_update_patient` normaliza carnet/registro, preserva historia única y matrícula; comparar restricciones únicas e integridad. UUID generado solo para creaciones; las pruebas usan correspondencia documentada.
- Asignación: versión vigente 20260920150100 admite INITIAL/SPECIALTY/REFERRAL y bloquea solicitud/cupo; comprobar compatibilidad, capacidad/solapamientos, eventos y transición de derivación con dos sesiones concurrentes. El mock verifica parámetros, no serialización ni atomicidad.
- Cancelación: `rpc_cancel_appointment_request` retorna void y afecta solicitud/cita/capacidad según estado; llegada/ausencia también retornan void. No reemplazar `data:null` por `{}` o eliminar data.
- Inicio: `rpc_open_encounter` vigente 20261006100000 crea historia especializada si corresponde, vincula versión vigente de antecedentes y modifica derivación/estado. Ruta primero comprueba personal/cita/borrador y devuelve 201/200. Probar repetición concurrente en base, no solo reuso secuencial del handler.
- Antecedentes: guard de rol + relación clínica; lectura `{current,encounter}`; ruta siempre envía encounter null en GET. Escritura última 20261006110000 valida listas/status, bloquea historia y expectedVersion; conflicto 40001; agrega versión y motivo/actor, conserva vínculo histórico.
- Revisión: cierre vigente 20260921100000 produce JSON con encounterId/referralId, persiste review_history_version, mediciones y diagnóstico; cita ATTENDED y derivación opcional en misma RPC. Química ATTACHED exige documento disponible. Probar rollback si falla especialidad o ficha después de escrituras previas.
- Especialidad: última 20260930190000 requiere ficha del código del área, crea versión, cierra atención/cita y derivación IN_PROGRESS; retorna void. La ruta reenvía `data` del cliente: la fixture simula null; confirmar serialización PostgREST de void en captura real.
- Documentos: preparar metadatos → Storage.upload(upsert:false) → finalizar. No hay transacción entre Storage y PostgreSQL en la ruta; ante fallo puede quedar metadato/objeto pendiente. Descargar consulta AVAILABLE y firma por 60 s. No afirmar checksum/validación de contenido si el código vigente solo valida MIME/tamaño declarado.
- Reportes: última rpc_clinical_report en 20261007100000; mezcla columnas SQL snake_case con filtros camelCase; revisar retorno exacto del cuerpo. Registro de exportación confía en rowCount/filters enviados por cliente en ruta actual y no genera archivo. Corregir ese límite de confianza en nuevo backend como diferencia deliberada, no como paridad ya garantizada.
- RLS clínica: última política por área 20261006120000 y helpers can_read_clinical_patient/can_read_clinical_encounter/can_read_document/can_read_referral. Revisión ve INITIAL con relación; especialista su área vigente y revisión concreta remitida; permiso excepcional de documento tiene vencimiento. La ruta de ficha filtra además encuentros/derivaciones/documentos, y puede ser más restrictiva que RLS.
- `can_read_clinical_encounter` admite revisión origen por derivación asignada sin condición explícita de estado activo en esa rama del helper: no sustituir silenciosamente por regla documental de derivación activa; registrar diferencia y evaluar seguridad.
- Política write-deny, SELECT por propietario/rol, helper SECURITY DEFINER con search_path vacío y permisos de ejecución deben comprobarse por rol PostgreSQL real. Reemplazar auth.uid por contexto transaccional propio en Spring; no usar runtime owner/BYPASSRLS.

## Consultas auxiliares fuera de las 24 rutas

`rpc_daily_activity` y `rpc_compliance_report` se consumen directamente desde páginas administrativas y están en el índice. `src/app/actions/session.ts` hace login/logout/updateUser/contraseña mediante Auth; `demo-session.ts` contiene sesión real pese al nombre; `proxy.ts` refresca claims. `consumers.json` registra rutas y archivos para evitar migración incompleta.

## Verificar catálogo desplegado sin exportar pacientes

Ejecutar desde conexión de lectura autorizada a la base de PRUEBA y guardar resultado fuera del repositorio si contiene configuración de acceso:

```sql
SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid),
       pg_get_functiondef(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('public','private')
ORDER BY 1,2,3;
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies WHERE schemaname IN ('public','storage')
ORDER BY 1,2,3;
SELECT n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname IN ('public','storage') AND c.relkind='r';
```

Contrastar definiciones y grants de instancia con snapshots antes de afirmar que son la versión desplegada. Revisar `complete_schema.sql` como artefacto consolidado, no ejecutar ambos archivos como dos esquemas independientes.

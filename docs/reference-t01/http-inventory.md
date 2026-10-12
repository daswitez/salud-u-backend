# Inventario HTTP de referencia

Generado desde código; revisar los snapshots de sources para transformaciones completas. Roles vacíos no significan acceso autorizado en base de datos. Query/bodyFields son extracción de lecturas directas, no esquema JSON completo.

| Método | Ruta | Guard de ruta | RPC | Fuente |
| --- | --- | --- | --- | --- |
| GET | `/api/administrative/referrals` | ADMINISTRATIVE | rpc_list_referrals_for_administration | src/app/api/administrative/referrals/route.ts:8 |
| POST | `/api/appointment-requests/[requestId]/assign` | ADMINISTRATIVE | rpc_assign_appointment_request | src/app/api/appointment-requests/[requestId]/assign/route.ts:8 |
| PATCH | `/api/appointment-requests/[requestId]` | STUDENT, ADMINISTRATIVE | rpc_cancel_appointment_request | src/app/api/appointment-requests/[requestId]/route.ts:8 |
| GET | `/api/appointment-requests` | STUDENT, ADMINISTRATIVE | consulta/retorno local | src/app/api/appointment-requests/route.ts:19 |
| POST | `/api/appointment-requests` | STUDENT, ADMINISTRATIVE | rpc_create_appointment_request_for_patient, rpc_create_initial_appointment_request | src/app/api/appointment-requests/route.ts:42 |
| POST | `/api/appointments/[appointmentId]/check-in` | ADMINISTRATIVE | rpc_check_in_appointment | src/app/api/appointments/[appointmentId]/check-in/route.ts:8 |
| POST | `/api/appointments/[appointmentId]/no-show` | ADMINISTRATIVE | rpc_mark_appointment_no_show | src/app/api/appointments/[appointmentId]/no-show/route.ts:8 |
| GET | `/api/availability-slots` | ADMINISTRATIVE, REVIEW_DOCTOR, SPECIALIST | consulta/retorno local | src/app/api/availability-slots/route.ts:18 |
| POST | `/api/availability-slots` | REVIEW_DOCTOR, SPECIALIST | rpc_create_my_availability_block, rpc_publish_availability_slot, rpc_replace_my_availability_schedule | src/app/api/availability-slots/route.ts:70 |
| DELETE | `/api/availability-slots` | REVIEW_DOCTOR, SPECIALIST | rpc_delete_my_availability_block | src/app/api/availability-slots/route.ts:104 |
| GET | `/api/careers` | no-explicit-route-guard | consulta/retorno local | src/app/api/careers/route.ts:7 |
| GET | `/api/health/supabase` | no-explicit-route-guard | consulta/retorno local | src/app/api/health/supabase/route.ts:12 |
| GET | `/api/me` | session-only | consulta/retorno local | src/app/api/me/route.ts:9 |
| POST | `/api/medical/appointments/[appointmentId]/start` | REVIEW_DOCTOR, SPECIALIST | rpc_open_encounter | src/app/api/medical/appointments/[appointmentId]/start/route.ts:8 |
| GET | `/api/medical/appointments` | REVIEW_DOCTOR, SPECIALIST | consulta/retorno local | src/app/api/medical/appointments/route.ts:35 |
| GET | `/api/medical/documents/[documentId]/download` | REVIEW_DOCTOR, SPECIALIST | consulta/retorno local | src/app/api/medical/documents/[documentId]/download/route.ts:8 |
| POST | `/api/medical/documents` | REVIEW_DOCTOR, SPECIALIST | rpc_create_document_upload, rpc_finalize_document_upload | src/app/api/medical/documents/route.ts:11 |
| POST | `/api/medical/encounters/[encounterId]/finalize` | REVIEW_DOCTOR, SPECIALIST | rpc_finalize_initial_encounter, rpc_finalize_specialty_encounter | src/app/api/medical/encounters/[encounterId]/finalize/route.ts:48 |
| GET | `/api/medical/patients/[patientId]/clinical-background` | REVIEW_DOCTOR, SPECIALIST | rpc_get_clinical_background | src/app/api/medical/patients/[patientId]/clinical-background/route.ts:9 |
| PATCH | `/api/medical/patients/[patientId]/clinical-background` | REVIEW_DOCTOR, SPECIALIST | rpc_save_clinical_background | src/app/api/medical/patients/[patientId]/clinical-background/route.ts:19 |
| GET | `/api/medical/patients/[patientId]` | REVIEW_DOCTOR, SPECIALIST | rpc_get_clinical_background | src/app/api/medical/patients/[patientId]/route.ts:11 |
| GET | `/api/my-specialties` | REVIEW_DOCTOR, SPECIALIST | consulta/retorno local | src/app/api/my-specialties/route.ts:8 |
| GET | `/api/patients/[patientId]/initial-history` | no-explicit-route-guard | consulta/retorno local | src/app/api/patients/[patientId]/initial-history/route.ts:9 |
| PUT | `/api/patients/[patientId]/initial-history` | no-explicit-route-guard | consulta/retorno local | src/app/api/patients/[patientId]/initial-history/route.ts:10 |
| GET | `/api/patients/[patientId]/referrals` | ADMINISTRATIVE | rpc_list_patient_referrals_for_appointment | src/app/api/patients/[patientId]/referrals/route.ts:8 |
| GET | `/api/patients/[patientId]` | ADMINISTRATIVE | consulta/retorno local | src/app/api/patients/[patientId]/route.ts:13 |
| PATCH | `/api/patients/[patientId]` | ADMINISTRATIVE | rpc_register_or_update_patient | src/app/api/patients/[patientId]/route.ts:36 |
| GET | `/api/patients` | ADMINISTRATIVE | consulta/retorno local | src/app/api/patients/route.ts:31 |
| POST | `/api/patients` | ADMINISTRATIVE | rpc_register_or_update_patient | src/app/api/patients/route.ts:53 |
| GET | `/api/reports/clinical` | ADMINISTRATIVE, REVIEW_DOCTOR, SPECIALIST | rpc_clinical_report | src/app/api/reports/clinical/route.ts:22 |
| POST | `/api/reports/clinical` | ADMINISTRATIVE, REVIEW_DOCTOR, SPECIALIST | rpc_log_clinical_report_export | src/app/api/reports/clinical/route.ts:35 |
| GET | `/api/specialties` | REVIEW_DOCTOR, SPECIALIST, ADMINISTRATIVE | consulta/retorno local | src/app/api/specialties/route.ts:8 |

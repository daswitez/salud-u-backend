# Lectura de los contratos HTTP

Inventario completo por método: `http-inventory.json`/`.md`. Respuestas y declaraciones de tipo extraídas del AST: `response-expressions.json`. Payload/solicitud de cada caso: `fixtures/cases.json`. Las expresiones dinámicas se resuelven mediante los snapshots fuente y el contrato SQL; no se fabrican esquemas para objetos JSONB libres.

| Ruta / método | Entrada y transformación relevante | Salida / estado de éxito |
| --- | --- | --- |
| GET me | sesión resuelta con Auth/perfil/roles activos; prioridad ADMINISTRATIVE, REVIEW_DOCTOR, SPECIALIST, STUDENT | 200 `{ok,user:{id,email,name,role,clinicalRole}}`; no data |
| GET health/supabase | cliente privilegiado, count especialidades habilitadas | 200 ok/service/enabledSpecialties; 503 database_unavailable; 500 configuration_error; no guard explícito |
| GET careers | catálogo is_active, order name | 200 data[] id/code/name; sin guard de ruta; error DB siempre 400 sin code (excepción al helper común) |
| GET specialties | rol interno, is_enabled, order name | 200 data[] id/code/name |
| GET my-specialties | médico; staff_member por profile_id, relación staff_specialty | 200 data[]; no filtro temporal explícito en ruta; confirmar reglas en RLS |
| GET patients | query trim/max80, elimina , % ( ); archived_at null; family_names; límite100 | data[] camelCase con givenNames/familyNames y enrollment/career nullable; selección matrícula ACTIVE o primera sin order explícito |
| POST patients | fullName split por mitad redondeada; carnet/registro max40, carrera/período/inicio obligatorios; phone/email vacíos a null | 201 data.id; nacimiento regex de fecha, no validación calendario en helper |
| GET patients/{id} | paciente no archivado y matrícula ACTIVE/primera | 200 objeto data, sin givenNames/familyNames; no encontrado 404; career se toma con [0] |
| PATCH patients/{id} | valores omitidos carnet/registro/nacimiento conservan actual; phone/email omitidos se convierten a null; fullName opcional | 200 data.id; JSON inválido 400; no encontrado 404 |
| GET/PUT patients/{id}/initial-history | retirada funcional, sin guard explícito | 410 mensaje exacto; no consulta DB |
| GET patients/{id}/referrals | administrativo, patientId text max50 | 200 data[] con columnas retornadas por RPC, sin conversión a camelCase |
| GET administrative/referrals | administrativo | 200 data[] SQL; orden prioridad de estado y created_at desc |
| GET appointment-requests | estudiante/administrativo; requested_at desc; relaciones objeto/array se normalizan con first | 200 data[] snake_case; appointment conserva snake_case y añade doctorName/endsAt; availability_slot undefined se omite del JSON |
| POST appointment-requests | INITIAL por defecto; administrativo con patientId; estudiante rechaza patientId aunque sea propio; REFERRAL/SPECIALTY solo administrativo | 201 data.id; 400/403 de validación exactos |
| PATCH appointment-requests/{id} | action='cancel', reason trim/max300 o null | 200 data:null |
| POST appointment-requests/{id}/assign | slotId obligatorio max50 | 200 data.appointmentId |
| POST appointments/{id}/check-in | administrativo, path appointmentId | 200 data:null |
| POST appointments/{id}/no-show | administrativo, reason max300/null | 200 data:null |
| GET availability-slots | normal: PUBLISHED futuro, order starts_at, límite100; médico solo propietario; initial=true filtra specialty null | 200 data[] snake_case que conserva staff y añade doctorName; no excluye booked_count==capacity en ruta |
| GET availability-slots?manage=true | médico; from/to regex o hoy La Paz; intervalo inclusivo días locales | 200 data objeto schedules/recurringBlocks/dateBlocks/slots raw, appointments con id/slotId/status/scheduledFor/patientName |
| POST availability-slots | prioridad: rules array → horario; dateBlock true → bloqueo; resto → cupo; capacity acepta string numérica vía Number | 200 generatedSlots para horario; 201 data.id para bloqueo/cupo; parámetros completos en llamadas registradas |
| DELETE availability-slots | blockId query max50 obligatorio | 200 data:null |
| GET medical/appointments | personal activo propio; order scheduled_for asc; límite200 | 200 data[] camelCase, patient nullable, specialty fallback Revisión estudiantil; personal ausente 404 |
| POST medical/appointments/{id}/start | médico dueño; tipo INITIAL para revisión, no INITIAL para especialista; SCHEDULED/CHECKED_IN; recuperar borrador antes de RPC | 201 encounterId/DRAFT nuevo; 200 encounterId/status existente; dueño inválido 404, estado incompatible 409 |
| GET medical/patients/{id} | relación clínica/RLS; área vigente; origen remitido; mezcla consultas y normalizaciones | 200 patient/intake/clinicalBackground/encounters/diagnoses/referrals/appointments/documents; campos anidados mixtos; accessReason AREA/REFERRAL_SOURCE; varios null; ajeno 404 |
| GET medical/patients/{id}/clinical-background | RPC patientId, encounter null | 200 data:{current,encounter}; puede contener null |
| PATCH medical/patients/{id}/clinical-background | expectedVersion entero≥0 o 0; changeReason obligatorio max500; normaliza legacy details/items/status/habits | 200 versión JSON; conflicto DB 40001 → 409 |
| POST medical/encounters/{id}/finalize | revisión/especialista; chiefComplaint/assessment obligatorios; histories normalizadas schemaVersion1; number 0..100000; textos truncados; conduct booleans estrictos | revisión data:{encounterId,referralId}; especialidad reenvía data de retorno void (mock null, pendiente verificar PostgREST); defaults NOT_PRESENTED/ROUTINE |
| POST medical/documents | multipart file/patientId/encounterId/documentType; descripción max1000; fecha regex; PDF/JPG/PNG/WEBP 0<size≤15 MiB | 201 data.id; prepara → upload → finalize; resultado preparación array/objeto aceptado; vacío500; Storage error por helper |
| GET medical/documents/{id}/download | documento AVAILABLE; firma bucket/path por60 segundos | 200 data.url; unavailable404; firma fallida400 si sin código |
| GET reports/clinical | from/to, specialtyId, encounterType, diagnosis, allergies/histories/habitTerms/positiveHabits JSON arrays de strings, search; trim/dedupe/max15 términos de200 | 200 `{ok,data,filters}`; rango/tipo/hábito inválido400; columnas data según RETURNS TABLE vigente |
| POST reports/clinical | format CSV/XLSX/PDF; rowCount Number entero0..10000; purpose default Gestión clínica; filters objeto no array | 201 data.id; solo registro de exportación, no archivo |

## Errores comunes y diferencias a conservar

Guard: sin sesión `{ok:false,error:"unauthenticated"}`/401; rol rechazado forbidden/403. `supabaseError`: 42501→403, 23505/40001→409, P0002→404, otros→400; cuerpo `{ok:false,error:message,code:code??"DATABASE"}`. Errores de validación locales generalmente no tienen code. No confundir estos cuerpos con `ApiResult` de `ui-contracts.ts`, que define error objeto/requestId pero no refleja estas rutas reales.

Objetos JSON se comparan sin importar orden de claves; arrays en orden, null distinto de ausente, string distinto de number. `date()` solo regex; JSON literal null en rutas que usan body.action sin optional chaining puede arrojar excepción fuera del envelope. Estas limitaciones se registran como comportamiento/fallo actual y se evalúan como correcciones al migrar, sin perpetuar fallos de seguridad para obtener paridad.

`NextResponse` en suite es un adaptador JSON basado en Response; no ejecuta Next, proxy.ts, cookies SSR ni cabeceras generadas por el framework. Content-Type JSON se comprueba en adaptador; confirmar HTTP real en ensayo. Salud 500 por configuración y excepciones inesperadas están documentadas pero no todas tienen fixture de ejecución.

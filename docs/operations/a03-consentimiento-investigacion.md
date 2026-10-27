# A-03 · Términos de uso y consentimiento para investigación

Fecha: 27 de octubre de 2026. Estado: **terminada en el backend; paso 1 de la puesta en marcha activo**. Migración: `V96__consentimiento_investigacion.sql`.
Trazabilidad: exportación para investigación (sección 3.3), RN-22, RN-23; tabla `consentimiento` del modelo de gobierno.

## 1. Datos

- **`texto_consentimiento`:** `tipo` (USO_SISTEMA o INVESTIGACION), `version`, `texto`, `vigente_desde`; única por (tipo, versión).
  - La vigente de cada tipo es la última con `vigente_desde <= now()`.
  - Se cargó la versión `1` de ambos, vigente desde el 27/10/2026. **Son un borrador:** el centro debe revisarlos y, si cambian, se publica una versión nueva con otra migración.
  - El texto de investigación dice expresamente que nunca se incluyen nombre, carnet, código de registro, teléfono ni correo, y que responder No no cambia la atención.
- **`consentimiento`:** `id_paciente`, `tipo`, `version` (clave foránea al texto), `decision` (ACEPTA o RECHAZA), `via` (PORTAL o ADMINISTRACION), `registrado_por`, `registrado_en` e `id_documento_evidencia` opcional.
  - **Solo inserción:** el trigger `proteger_consentimiento` rechaza UPDATE y DELETE, también para el migrador. Cambiar de opinión es una fila nueva.
  - **Términos:** el mismo trigger rechaza una fila USO_SISTEMA con RECHAZA. No va en un CHECK porque cruza dos columnas y la prueba del diccionario lee los literales de cada CHECK.
  - **Decisión vigente:** la última fila del paciente para ese tipo y la **versión vigente**. Una versión nueva deja a todos pendientes hasta que respondan, y mientras tanto quedan fuera de la exportación.
  - **`id_documento_evidencia`:** sin clave foránea, porque `documento_clinico` exige una atención y el formulario en papel no la tiene. Por ahora no se expone en la API.
- **Seguridad:** RLS ENABLE + FORCE, solo la política del migrador y ningún permiso para el rol de ejecución.
- **Diccionario:** dominios `tipo_consentimiento` (TERMS, RESEARCH), `decision_consentimiento` (ACCEPTED, DECLINED) y `via_consentimiento` (PORTAL, ADMINISTRATION). Quedan 132 equivalencias y 39 dominios.

## 2. Quién hace qué

| Rol | Acceso | Funciones |
|---|---|---|
| Estudiante | Ve y responde lo suyo; no recibe id de paciente | `obtener_mis_consentimientos`, `registrar_mis_consentimientos` |
| Administración | Ve y registra lo de cualquier paciente vigente | `obtener_consentimientos_paciente`, `registrar_consentimientos_paciente` |
| Ambos | Pregunta si falta responder (NULL = la ficha propia; el estudiante no puede preguntar por otro) | `consentimiento_pendiente(p_id_paciente)` |
| Reportes | Solo los conteos de excluidos de sus exportaciones | `registrar_exportacion_investigacion`, `obtener_exportacion_investigacion` |

- **Registro:** `escribir_consentimientos` valida que los términos estén aceptados, que investigación tenga Sí o No y que las versiones sean las vigentes. Inserta solo lo que cambia y bloquea la fila del paciente para serializar respuestas simultáneas por el portal y en recepción.
- **Auditoría:** `CONSENTIMIENTO_REGISTRADO` sobre el recurso `paciente`, con `tipo`, `version`, `decision`, `via` e `idConsentimiento`. Repetir la misma respuesta no genera un evento.

## 3. API

- **`GET /api/me/consents` y `GET /api/patients/{id}/consents`** devuelven `{pending, terms, research}`. Cada uno trae `{currentVersion, text, accepted, lastAnswer}`.
  - `accepted` es true o false para la versión vigente, o null si falta responderla.
  - `lastAnswer` es `{version, accepted, channel, recordedAt}`, o null.
- **`POST /api/me/consents` y `POST /api/patients/{id}/consents`** reciben `{termsVersion, termsAccepted: true, researchVersion, researchAccepted: true|false}` y devuelven el estado actualizado.
  - **400:** términos no aceptados, investigación sin elegir Sí o No, o versiones ausentes.
  - **409:** las versiones ya no son las vigentes, porque cambió el texto mientras se leía.
- **`POST /api/patients`** acepta `consents`. Se guarda en la misma transacción que el paciente: si es inválido (400) o desactualizado (409), no se crea el paciente.
- **`POST /api/appointment-requests`** acepta `consents` para los tres tipos de solicitud. Si llega, se registra antes de crear la solicitud.
- **422 `CONSENTIMIENTO_PENDIENTE`:** si el paciente tiene la respuesta pendiente y no se envía `consents`, `POST /api/appointment-requests` responde `{ok: false, error, code: "CONSENTIMIENTO_PENDIENTE"}`, tanto para el estudiante como para Administración. El campo `code` es nuevo en el sobre `{ok, error}` y sirve para que la pantalla abra el diálogo.

## 4. Puesta en marcha

| Paso | Qué hace | Estado |
|---|---|---|
| 1 | El backend acepta `consents` como opcional y lo registra si llega | **Activo** (`salud-u.consents.required=false` por defecto) |
| 2 | El frontend lo envía siempre (F-10) | Pendiente |
| 3 | El backend lo exige (422) | Implementado y probado; se enciende con `SALUD_U_CONSENTS_REQUIRED=true` |

- **Pacientes existentes:** no reciben respuesta por defecto. Quedan pendientes y fuera de la exportación hasta que respondan en el portal o en recepción.

## 5. Exportación para investigación

- **`filas_investigacion` (privada):** tiene el mismo cuerpo que la exportación anterior, más `id_paciente` y el estado del consentimiento.
- **`conjunto_investigacion_seudonimizado`:** solo devuelve las filas con INVESTIGACION = ACEPTA en la versión vigente. Sus columnas no cambian.
- **Registro de la exportación:** `registrar_exportacion_investigacion` guarda en `exportacion_investigacion` las columnas `excluidos_por_rechazo` y `excluidos_sin_respuesta`. Son pacientes distintos con atenciones dentro de los filtros, no filas, y también van en la auditoría.
  - La descarga los devuelve en los encabezados `X-Excluded-Declined` y `X-Excluded-Unanswered`.
  - La constancia los devuelve como `excludedDeclined` y `excludedUnanswered`, que valen null en las exportaciones anteriores.
- **Cambio de comportamiento intencional:** en la base local, después de V96 ninguna de las 306 atenciones es exportable hasta que sus pacientes respondan. El fixture de la prueba de investigación de `DatabaseActorContextIntegrationTest` ahora registra ACEPTA.

## 6. Evidencia

- **`ConsentimientoIntegrationTest`** (4 pruebas, con la obligación activa):
  - **Sin aceptar términos o sin elegir Sí o No no se avanza:** cinco cuerpos inválidos dan 400 en el portal y en Administración. En el alta de paciente, un 400 o un 409 no crea al paciente. El 422 se cumple para el estudiante y para Administración, y no se crea ninguna solicitud ni respuesta.
  - **Responder No permite pedir citas:** por el portal y en recepción, con `consents` en la solicitud y en el alta. Se audita con la vía correcta, y repetir la misma respuesta no agrega filas.
  - **Un estudiante no responde por otro:** un `patientId` en el cuerpo se ignora; da 403 en las rutas de Administración y de la solicitud. `consentimiento_pendiente` del paciente de otro falla. Reportes y médicos reciben 403, y una cuenta sin ficha 404. El rol de ejecución no lee las tablas. Las filas son inmutables y los términos no se pueden rechazar.
  - **Exportación:** con Sí, Sí y sin respuesta hay 2 filas, 0 excluidos por No y 1 sin respuesta. Si uno cambia a No, la siguiente exportación tiene 1 fila, 1 por No y 1 sin respuesta, también en la constancia y la auditoría. El CSV no contiene nombre, apellido, carnet, registro, teléfono, correo ni el id de ningún paciente, y su encabezado es el de siempre. Una versión 2 deja pendiente a quien aceptó la 1, que vuelve a recibir 422 y queda fuera de la exportación; la respuesta con la versión vieja da 409 y con la 2 lo devuelve.
- **`PatientControllerMvcTest`:** sin `consents` el servicio no se llama (paso 1); con `consents` se registra; sin Sí o No da 400.
- **`ResearchExportControllerMvcTest`:** los encabezados de excluidos.
- **`EsquemaEspanolIntegrationTest`:** las tres columnas de código mapeadas a sus dominios.
- **`mvn verify`:** 312 pruebas, 0 fallos; cobertura de funciones SQL 162 de 164 (las mismas 2 sin cubrir de antes).
- **Ensayo** sobre una copia de la base local:
  - la migración aplica en una transacción;
  - antes de responder, 306 de 306 filas pendientes;
  - el estudiante pasa de pendiente a no pendiente al responder Sí, y sus 16 filas pasan a ser exportables;
  - diccionario 132/39.
- **Despliegue local:**
  - respaldo `backups/salud-u-20261027T083306Z.dump`;
  - Flyway en 96 y readiness 200;
  - 0 funciones ejecutables por PUBLIC y 0 ERROR/WARN en los logs;
  - `/api/me/consents` sin sesión responde 401.

## 7. Fuera de alcance y pendiente

- **F-10 (frontend):** la pantalla de bloqueo en `estudiante/layout.tsx`, el cambio de respuesta en el perfil, el bloque obligatorio en el registro y el diálogo en `check-in` y `solicitudes`. Los proxies `/api/me/consents` y `/api/patients/:patientId/consents` ya están en `next.config.ts`.
- **Sin pantalla de administración de textos:** una versión nueva se publica con una migración.
- **`autorizacion_excepcion` y `autorizacion_acceso_documento`:** quedan fuera, como dice la historia. Los menores de edad los registra Administración con la firma del tutor; la subida del formulario firmado no está hecha.

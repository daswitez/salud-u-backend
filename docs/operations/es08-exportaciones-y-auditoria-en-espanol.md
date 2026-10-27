# ES-08 · Exportaciones y auditoría en español

Fecha: 26 de octubre de 2026 (America/La_Paz). Estado: **terminada y aplicada localmente**.
Migración: `V79__exportaciones_y_auditoria_en_espanol.sql`.

## Datos y compatibilidad

- `exportacion_reporte_clinico.estado`: COMPLETED/FAILED → COMPLETADA/FALLIDA. Se recrearon los CHECK de estado e integridad del checksum en español, conservando su semántica.
- `codigo_resultado_auditoria`: `ALTER TYPE ... RENAME VALUE` para SUCCESS → EXITO, DENIED → DENEGADO y FAILURE → FALLO. PostgreSQL conserva los valores internos del enum y cambia sus etiquetas; no se ejecutó UPDATE sobre eventos históricos.
- `AuditOutcome` conserva sus miembros Java. `AuditWriter` convierte sus tres valores a las etiquetas españolas antes de llamar a SQL.
- El registro de exportaciones recibe los códigos HTTP y los traduce con `desde_codigo_api`; el comprobante devuelve los códigos HTTP con `a_codigo_api`. También se conservan SUCCESS/DENIED/FAILURE en las respuestas y filtros HTTP de auditoría.
- Las **acciones y recursos** devueltos por auditoría pasan intencionalmente al código actual en español, conforme a ES-08. Los consumidores que filtran con códigos antiguos continúan funcionando.

## Evidencia histórica inmutable (RN-27)

**Los eventos anteriores al corte conservan sus códigos originales de acción y tipo de recurso.** No se actualizan ni eliminan sus filas. La consulta muestra el código actual a través de equivalencias; no modifica la evidencia original. El resultado cambia de etiqueta mediante el renombrado del enum, conservando su valor interno.

`salud_u.equivalencia_codigo_auditoria(codigo_anterior, codigo_actual)` contiene **54 equivalencias**: 33 acciones y 21 tipos de recurso, incluidos los códigos de catálogos y recursos sintéticos conocidos de los ensayos. Su clave es el código anterior, sin imponer unicidad al destino. Tiene RLS forzada, política para el migrador y ningún acceso directo para PUBLIC ni el rol runtime.

`listar_eventos_auditoria_paginados` une dos veces el diccionario y devuelve los códigos actuales. Los filtros parciales de acción/recurso buscan el valor guardado, su código actual y los alias anteriores de ese código. Así, tanto `PATIENT_CREATED` como `PACIENTE_CREADO`, e incluso `PATIENT_`/`PACIENTE_`, encuentran eventos antiguos y nuevos. Se conservan el cursor de microsegundos, el orden y los límites de fecha en Bolivia. Los códigos propios no incluidos en el diccionario se devuelven sin alteración.

`agregar_evento_auditoria` recibe resultados en español. Como defensa para consumidores anteriores, normaliza las acciones y recursos conocidos al insertar; todos los emisores de producción SQL/Java actualizados ya usan los códigos españoles.

## Funciones y Java

Se reescribieron **14 funciones**: `agregar_adenda_encuentro`, `agregar_evento_auditoria`, `asignar_solicitud_cita`, `contexto_registro_vacunacion`, `finalizar_encuentro_revision` (12 parámetros), `guardar_vacuna_y_esquema`, `listar_eventos_auditoria_paginados`, `obtener_carnet_vacunacion`, `obtener_exportacion_reporte`, `registrar_dosis_vacuna`, `registrar_exportacion_investigacion`, `registrar_exportacion_reporte`, `reporte_cobertura_vacunacion` y `resolver_o_devolver_derivacion`.

Son `CREATE OR REPLACE`: no cambian firmas, permisos, validaciones clínicas ni estructura de las respuestas. Las llamadas de rol que se reescriben usan español. Los estados nuevos dentro de los detalles de auditoría de exportación se guardan en español; los detalles históricos no se modifican.

Se tradujeron las acciones y recursos de los emisores Java de pacientes, identidad, catálogos, personal, agenda, exportaciones y consulta de auditoría. `CatalogKind.auditResourceType()` obtiene el recurso español sin cambiar los códigos HTTP del catálogo.

El inventario de inglés exceptúa únicamente los códigos históricos de acción/recurso con equivalencia explícita. Un código inglés desconocido continúa apareciendo en el inventario. El diccionario y los códigos estables de API conservan su función de compatibilidad.

## Pruebas

Antes del cambio: `mvn -B -ntp verify`, **200 pruebas**, sin fallos, errores ni omisiones.

Después:

```bash
mvn -B -ntp -Dtest=EsquemaEspanolIntegrationTest -Dinventario.actualizar=true test
mvn -B -ntp verify
```

- **202 pruebas**, 0 fallos, 0 errores, 0 omitidas; `plpgsql_check` aprobado.
- Inventario: **260 → 217 elementos**.
- Nueva prueba `spanishAuditCodesNormalizeHistoricalReadsAndFiltersWithoutChangingStoredEvidence`: un evento con códigos históricos y tres nuevos; los tres resultados se guardan en español y salen como códigos de API; filtros exactos/parciales antiguos y actuales equivalentes; los valores históricos almacenados permanecen; actualización y borrado denegados; diccionario privado; códigos propios preservados.
- Nueva prueba `failedReportExportStoresSpanishStateAndOutcomeWhileReceiptKeepsApiCode`: FALLIDA y FALLO guardados, comprobante FAILED por API, e integridad que rechaza una exportación completada sin checksum.
- Los escenarios existentes cubren exportación completada, rollback, filtros de auditoría, permisos, sesión, reportes, derivaciones y vacunación.

## Aplicación local y datos existentes

Respaldo previo: `backups/salud-u-20261027T025249Z.dump`.

`docker compose up -d --build backend` completado; Flyway **V79** aplicada; `/actuator/health` devuelve **UP**. El build pasa sus pruebas disponibles (48 omitidas por no disponer de Docker dentro del build); la ejecución Maven del host sí ejecutó las 202 sin omisiones.

Antes y después se compararon huellas por UUID de la fila JSONB completa, normalizando únicamente los resultados del enum y estados de exportación a sus códigos API:

- **7.462 eventos de auditoría**, todos coinciden. Acciones, recursos, actor, fechas, identificadores y detalles se compararon sin traducir ni excluir campos.
- **90 exportaciones**, todas coinciden.
- Tras migrar y antes de las pruebas de navegador: EXITO 7.337, DENEGADO 60, FALLO 65; COMPLETADA 85, FALLIDA 5.

Las pruebas posteriores de navegador agregan cuentas y eventos sintéticos identificados FE24. No se borran eventos de auditoría para limpiar el ensayo.

Por esos eventos, V79 incluye las equivalencias `fixture_event` → `evento_prueba` y `audit_fixture` → `prueba_auditoria`. La auditoría de la base de desarrollo conserva unos 190 eventos `fixture_event` de las regresiones FE-24; son datos de prueba de esa base, no de operación, y una instalación nueva no los tiene. El documento académico debe presentarlos así (D-07).

## Pantalla y documento

La pantalla ya mostraba acción/recurso como texto y mantenía etiquetas españolas para los resultados HTTP; no requirió adaptar su contrato. Se añadió una explicación de los códigos actuales, la evidencia histórica preservada y los filtros por códigos anteriores.

Chromium aprobó `scripts/test-fe24.mjs`: fechas de Bolivia, filtros, cursor, recarga, errores recuperables, permisos AUDITOR y multirrol, inmutabilidad, eventos persistidos y ausencia de detalles sensibles. Captura y resultado: `/tmp/salud-u-es08-fe24-evidence/`.

Una segunda comprobación en una instancia temporal del frontend actualizado (`127.0.0.1:3001`) confirmó 25 eventos PACIENTE_CREADO/paciente/Exitoso y los mismos IDs al filtrar con códigos antiguos o actuales. Captura `es08-codigos-espanol.png` y resultado `es08-pantalla.json` en esa carpeta. La instancia temporal se detuvo; el frontend de producción local existente en el puerto 3000 no se reinició.

El texto de política para incorporar al documento académico queda registrado en D-07 del backlog vigente: las acciones y recursos anteriores al corte conservan su código original; los listados proyectan el código actual y aceptan ambos al filtrar. El archivo Word no se regeneró en esta historia.

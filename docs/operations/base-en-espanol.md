# Base de Salud-U en español

Fecha: 27 de octubre de 2026 (America/La_Paz). **ES-00 a ES-10 cerradas técnicamente en V81. Estado actual: Flyway V84 tras N-03, inventario cero.**

## Regla del borde

Los nombres del esquema y sus dominios internos están en español. El contrato HTTP mantiene sus campos, códigos y formatos existentes. Una función pública recibe códigos HTTP y usa `desde_codigo_api(dominio,codigo)` al entrar; opera con valores españoles y usa `a_codigo_api(dominio,valor)` al salir. NULL sigue siendo NULL; un valor desconocido lanza CODIGO_DOMINIO_DESCONOCIDO (22023).

`equivalencia_codigo_api(dominio,valor,codigo_api)` es la fuente de verdad: **96 equivalencias en 29 dominios**, con unicidad por dominio/valor y dominio/código. Tiene RLS forzada y no permite lectura directa al runtime. Sus funciones de conversión son STABLE, SECURITY DEFINER y fijan search_path. Las llamadas SQL internas usan valores españoles.

V81 añade INACTIVO/INACTIVE al dominio del esquema de vacunación y dos dominios solo de API: `tipo_diagnostico` (CONFIRMADO/CONFIRMED) y `dato_ausente` (NO_REGISTRADO/UNKNOWN). Así no se reutiliza un dominio con significado diferente para una constante de salida.

## Migraciones

- V72: diccionario API y retiro de funciones sin uso.
- V73: roles.
- V74: agenda.
- V75: atención clínica.
- V76: derivaciones.
- V77: documentos.
- V78: pacientes, inscripción y correo.
- V79: exportaciones y auditoría.
- V80: nombres de funciones/parámetros/salidas, restricciones, índices y políticas; consumidores Java.
- **V81: cierre de literales, códigos internos y roles tipados.** No se editó ninguna migración aplicada para implementar estas historias.
- V82 / N-01: tablas y generación transaccional de avisos de cita; añade ocho equivalencias de identidad españolas en tipo_evento_notificacion, canal_notificacion y estado_notificacion, sin reemplazar contratos previos. [Evidencia N-01](n01-avisos-de-cita-en-bandeja.md).
- V83 / N-02: cinco funciones de bandeja/preferencias propias e índice de entrega. Mantiene el diccionario en 95 equivalencias/29 dominios y el inventario en cero. [Evidencia N-02](n02-bandeja-y-preferencias-api.md).

- V84 / N-03: recordatorios programados del día anterior. Añade la identidad `RECORDATORIO_CITA` y `fecha_objetivo` interna; diccionario de 96 equivalencias/29 dominios e inventario cero. [Evidencia N-03](n03-recordatorios-programados.md).
- V85 / revisión: revoca a PUBLIC el EXECUTE de las funciones de `salud_u` y lo cierra por defecto para las nuevas, fuerza RLS en `rol_principal`, pasa a inglés los códigos de API de la bandeja (las nueve equivalencias cambian solo su `codigo_api`) y oculta los recordatorios sin vigencia. [Revisión V85](revision-v85-permisos-y-notificaciones.md).

## Qué cierra V81

- `tiene_rol_actor` recibe únicamente `salud_u.codigo_rol_aplicacion`. La firma `(text)` se elimina. Los códigos de rol HTTP ingleses se rechazan al intentar usarlos como enum.
- `DatabaseActorContext` sigue traduciendo los roles HTTP una vez por transacción al fijar el contexto. Spring, sus autoridades y `/api/me` conservan sus códigos.
- La única dependencia de catálogo del puente era la política `evento_auditoria_lectura_auditor`. Se recreó con el enum explícito y la llamada envuelta en SELECT, sin CASCADE ni cambios de permisos.
- Se pasan a español las llamadas pendientes de roles en las funciones de permisos, catálogos y especialidades.
- Los códigos que solo viajan SQL ↔ Java, sin ser parte de HTTP, se traducen simultáneamente en sus funciones y servicios:

| Antes | Ahora |
|---|---|
| AUTHENTICATED, INVALID, LOCKED | AUTENTICADO, INVALIDO, BLOQUEADO |
| INVALID_CURRENT_PASSWORD, EMAIL_ALREADY_USED | CONTRASENA_ACTUAL_INVALIDA, CORREO_YA_UTILIZADO |
| CREATED, UPDATED, NOT_FOUND | CREADO, ACTUALIZADO, NO_ENCONTRADO |
| DUPLICATE_CARNET, DUPLICATE_REGISTRATION, DUPLICATE_IDENTIFIER | CARNET_DUPLICADO, REGISTRO_DUPLICADO, IDENTIFICADOR_DUPLICADO |

Estos códigos internos no pasan por el diccionario. Las excepciones Java y los errores HTTP mantienen sus códigos públicos; por ejemplo EMAIL_ALREADY_USED continúa siendo un error HTTP válido.

- Rango de edad, ausencia de datos, estado de vacunación, cumplimiento, tipo de diagnóstico y acceso a historia se expresan internamente en español y se devuelven con el diccionario. El orden previo del reporte de cumplimiento se conserva.
- Los discriminadores SQL de disponibilidad pasan a `bloqueos_recurrentes` y `bloqueos_fecha`; Java conserva recurringBlocks y dateBlocks en la API.

## Auditoría histórica

Las acciones y recursos anteriores al corte **conservan sus códigos originales almacenados**. No se reescriben ni se eliminan eventos. El diccionario privado de 54 equivalencias de auditoría proyecta los códigos actuales al consultar y admite filtros con códigos antiguos o actuales. El resultado del enum cambió de etiqueta mediante RENAME VALUE sin cambiar su valor interno. Detalles y comprobaciones: [ES-08](es08-exportaciones-y-auditoria-en-espanol.md).

## Inventario cero y excepciones explícitas

`scripts/inventario-ingles.sql` enlaza al SQL canónico usado por las pruebas (`src/test/resources/inventario/inventario-ingles.sql`). Busca palabras conocidas en el catálogo vigente: tablas, columnas, funciones, argumentos/salidas, restricciones, índices, políticas, disparadores, enums, CHECK, literales de funciones y columnas de códigos. No busca en archivos históricos de migraciones, que son inmutables.

Se aceptan:

- Siglas y términos técnicos: CSV, XLSX, PDF, IMC, hash, token, checksum, MIME, JSON; sufijos técnicos de PostgreSQL pkey/fkey/key/check/idx.
- Códigos ingleses del contrato en los diccionarios de compatibilidad.
- Claves JSON y códigos devueltos del contrato HTTP. Los nombres y parámetros SQL y los valores internos no se exceptúan por esta regla.
- Códigos históricos de acción/recurso de auditoría únicamente si tienen equivalencia explícita. Un código inglés desconocido sigue apareciendo.
- Funciones de extensiones como pgcrypto, ajenas al dominio de la aplicación, y nombres técnicos de configuración/roles de despliegue.

El inventario usa un vocabulario explícito; cero hallazgos significa cero elementos detectados por esa regla, no una prueba lingüística de cada texto libre. No se añadieron exclusiones generales para conseguir el cierre.

```bash
SALUDU_PROJECT=salud-u-backend ./scripts/inventario-ingles.sh --exigir-cero
# Salida: 0; código de salida: 0.
SALUDU_PROJECT=salud-u-backend ./scripts/inventario-ingles.sh --detalle
# Sin filas.
```

La línea base de pruebas está vacía. La nueva prueba `cierreNoAdmiteInglesNiAmpliaLosPermisosDeFuncionesInternas` exige inventario vacío incluso al regenerar la línea base y comprueba que cuatro funciones internas siguen sin EXECUTE para runtime. La prueba de roles comprueba que la firma text ya no existe y rechaza los cinco códigos de API distintos de sus nombres españoles; AUDITOR coincide en ambos idiomas.

## Validación técnica

- V79 inicial: `mvn -B -ntp verify`, **202 pruebas**, sin fallos, errores ni omisiones.
- V80: mismo resultado de **202 pruebas**. Inventario **217 → 35**.
- V81: `mvn -B -ntp verify`, **203 pruebas**, sin fallos, errores ni omisiones, con caracterización y Testcontainers reales. `plpgsql_check` aprobado. Inventario **35 → 0**.
- El ajuste final para conservar el ORDER BY previo de cumplimiento se volvió a comprobar con `EsquemaEspanolIntegrationTest`, `DatabaseActorContextIntegrationTest` y `CaracterizacionFlujosIntegrationTest`: **49 pruebas**, todas aprobadas, sin omisiones.
- El test de roles se actualizó para el contrato final, sustituyendo la aceptación transitoria de nombres ingleses por su rechazo.
- `npm run typecheck`, ESLint del script nuevo y `git diff --check` aprobados.

## Aplicación local y comparación

- Respaldo anterior: `backups/salud-u-20261027T031419Z.dump`.
- `docker compose up -d --build backend` completado; Flyway V80 y V81 aplicadas y salud UP. El build no dispone de Docker y omite sus 49 pruebas de integración; estas sí se ejecutaron en el host.
- Se compararon huellas JSONB de todas las filas de las tablas del esquema, excluyendo solo Flyway. **16.039 filas previas de 40 tablas con datos conservadas sin cambios ni eliminaciones**. Las únicas adiciones de la migración son las tres equivalencias API descritas arriba. Las tablas vacías también se recorrieron.
- **24 consultas antes/después, 3.063 filas devueltas, idénticas** tras normalizar únicamente nombres SQL y discriminadores internos traducidos. Incluyen pacientes, cuentas, personal, derivaciones, catálogos, disponibilidad, citas, reportes clínicos, cumplimiento, vacunación e investigación, con contextos de Administración, revisión, especialista, estudiante y Reportes. Se ejecutaron en transacciones revertidas.
- La consulta de auditoría se validó aparte: el carnet genera un evento temporal con UUID/fecha nuevos durante el ensayo, impidiendo comparar directamente su hash entre dos ejecuciones. La integridad de las filas originales sí se comprobó con las huellas de todas las tablas; permisos, filtros y paginación se verifican con integración y navegador.

## Recorrido de frontend por rol

Chromium ejecutó `scripts/test-es10.mjs` con login por el formulario real para los seis roles y nueve vistas:

- Administración: pacientes y bandeja de derivaciones.
- Revisión: agenda y horarios.
- Especialista: agenda y derivaciones asignadas.
- Estudiante: carnet de vacunación y consulta de solicitudes.
- Reportes: reporte institucional y exportación CSV.
- Auditor: bandeja, códigos actuales y filtros históricos.

Además se verificaron claves HTTP inglesas de pacientes/reportes, resultados de auditoría, denegaciones cruzadas 403, vacuna duplicada 409 tras renombrar su restricción y logout 401. No hubo respuestas 5xx en las solicitudes de las páginas registradas. Capturas y resumen están en `/tmp/salud-u-es10-evidence/`.

El recorrido fue realizado por el agente con navegador automatizado e inspección de evidencia; no se presenta como validación humana del centro ni sustituye el cuestionario SUS de C-03.

```bash
ES10_PLAYWRIGHT=/tmp/salud-u-browser/node_modules/playwright/index.mjs \
ES10_CHROMIUM=/home/daswits/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome \
node scripts/test-es10.mjs
```

Los scripts de comparación de esta ejecución quedaron en `/tmp/es0910-datos.sql` y `/tmp/es0910-consultas.sql`; las huellas y salidas, en `/tmp/es0910-*-antes.txt` y `/tmp/es0910-*-despues.txt`. Las pruebas de navegador agregan datos sintéticos ES10 y su auditoría se conserva.

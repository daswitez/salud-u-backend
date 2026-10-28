# BE-CORTE — informe de aceptación integral

Actualización de estado: 2026-10-27 (corte inicial 2026-10-17; ensayos de plataforma/carga del 26 conservados como evidencia histórica). Sólo código, contenedores y datos sintéticos locales. No se conectó ni modificó una instancia institucional, Supabase ni archivos clínicos reales.

## Dictamen

**Integración local aceptada; corte productivo todavía no.** Las condiciones técnicas 1–3 se cumplieron localmente con datos sintéticos, y el frontend completó FE-CORTE contra este backend ([evidencia](../../../salud-u/docs/evidencia-fecorte.md)). Siguen abiertas tres cosas que no se pueden cerrar sólo con código: el ensayo de migración de datos desde Supabase (condición 4), la estrategia de cuentas aprobada con el responsable institucional (condición 5) y la medición sobre el hardware de despliegue con un volumen acordado.

## Reejecución C-01/C-03 (27/10/2026)

Backend local V96: **312 pruebas, 0 fallos, 0 errores, 0 omitidas**, con registro reproducible y huellas en [A.6](../evaluacion/cierre-20261027/registro-a6.md). Recorrido mixto Next/Spring/PostgreSQL de ocho grupos por seis roles aprobado, con 47 respuestas Spring. [Evidencia C-03](../../../salud-u/docs/evidencia-cierre-c03.md). No se repitió la medición de carga/plataforma del 26 ni se presenta como ejecutada el 27.

C-03 permanece parcial: falta F-04/Figura 3.61 y la evaluación humana/SUS (sin respuestas reales, por confirmación del usuario). PA-23 tiene una observación de frontera operativa en O-05; [dictamen C-02](cierre-c01-c02.md). Estos hechos no cambian las condiciones pendientes del corte institucional indicadas abajo.

## Estado de las condiciones (2026-10-26)

| # | Condición | Estado | Evidencia |
| --- | --- | --- | --- |
| 1 | `pnpm install --frozen-lockfile`, `lint`, `typecheck`, `build` en `codigo/salud-u` | **PASA** | Corepack pnpm 12 con `pnpm-workspace.yaml` (`allowBuilds`); los cuatro comandos terminan sin errores. |
| 2 | `./scripts/verify-platform.sh` | **PASA** | "T-02 OK: build, Flyway, health/readiness, persistencia y respaldo/restauración verificados." Se corrigió el conteo de Flyway (`salud_u.flyway_schema_history`, sólo `type = 'SQL'`). |
| 3 | Volumen, regresión por roles, concurrencia y accesos entre áreas, p95 < 3 s | **PASA con volumen sintético** | `scripts/load-mixed.sh`: 3.000 pacientes, 9.000 atenciones cerradas (3.000 en el mes), 6.600 dosis; 360 búsquedas y reportes mensuales simultáneos de 8 actores con concurrencia 20: sin errores, sin mezcla entre actores, p95 global 695 ms, máximo 1,2 s (reporte clínico mensual). Falta repetirlo con el volumen acordado y en el hardware de despliegue. |
| 4 | Ensayo de migración con fixture sintético (UUID/FK/versiones/recuentos/checksums) y rollback | **PENDIENTE** | No existe todavía el mapeador Supabase → esquema Spring. Restauración y rollback del esquema Spring sí están probados (condición 2). |
| 5 | Estrategia de cuentas y contraseñas ensayada con el responsable institucional | **PENDIENTE** | Requiere decisión institucional (alta/importación con contraseña inicial o restablecimiento controlado). |

`mvn test`: 186 pruebas, 0 fallos, 0 errores, 0 omitidas (Testcontainers PostgreSQL).

## Defectos corregidos durante FE-CORTE

- **Agenda médica (V70):** con más de 200 citas el listado devolvía las 200 más antiguas y ocultaba las de hoy y las próximas. Ahora devuelve todas las activas y las 200 cerradas más recientes. Además `GET /api/medical/appointments/{id}` devuelve una cita propia, activa o cerrada.
- **Caída de PostgreSQL:** la sesión no se podía validar, la solicitud terminaba en `401` y la pantalla pedía iniciar sesión otra vez. Ahora responde `503 SERVICE_UNAVAILABLE` y conserva la cookie. La espera por conexión baja de 30 s a 5 s (`DB_CONNECTION_TIMEOUT_MS`).
- **Documentos sin escrituras partidas:** si el commit falla después de mover el archivo, el archivo se borra. `scripts/reconcile-documents.sh` concilia filas y archivos por SHA-256 (detecta huérfanos de una interrupción del proceso).
- **Cupos superpuestos:** publicar un cupo que choca con otro o con un bloqueo respondía `500`. Ahora responde `409` (y `400` para datos inválidos, como un horario pasado) con el mensaje de PostgreSQL.
- **Cupos publicados (V71):** el listado heredó el `limit(100)` de Supabase; con varios médicos se supera en pocas semanas y Administración dejaba de ver cupos asignables. Ahora devuelve todos los cupos futuros publicados.
- **Errores heredados:** el escritor de errores de seguridad ya no etiqueta como `forbidden` los estados distintos de 401/403.

## Trazabilidad funcional

La matriz completa y vigente está en [backlog-backend.md](../backlog-backend.md), líneas 610–637. Relaciona UC-01…UC-27 con BE-01…BE-27 y RF-01…RF-34, incluyendo BE-CAT para RF-28, BE-INV para RF-34 y el carácter transversal de RF-27.

La referencia HTTP de Next está caracterizada en [reference-t01/http-contract-notes.md](../reference-t01/http-contract-notes.md) y los contratos expuestos por Spring están en [`src/main/resources/static/openapi/salud-u-v1.yaml`](../../src/main/resources/static/openapi/salud-u-v1.yaml). El frontend `codigo/salud-u` (rama `backend`) ya consume sólo estos contratos; el código Supabase original quedó archivado en `reference-t01/sources/supabase`.

## Migración, recuperación y credenciales

`scripts/verify-platform.sh`, `scripts/backup.sh` y `scripts/restore.sh` ya delimitan un ensayo efímero: crean un proyecto Docker y una base temporales, aplican Flyway, hacen backup/restauración y eliminan sus recursos al final. El ensayo debe completarse antes de declararlo aprobado.

Eso no sustituye una migración histórica. El SQL serverless depende de `auth.users`, políticas RLS y Storage de Supabase, por lo que no puede cargarse como una migración Flyway de PostgreSQL independiente. Aún falta un mapeador y un fixture sintético aprobado que permitan comparar, antes y después de la migración, UUID, claves foráneas, versiones, recuentos y checksums de archivos.

Las cuentas tampoco se copian de manera implícita: Flyway deliberadamente no crea usuarios ni contraseñas de demostración. La estrategia documentada exige alta/importación institucional con contraseña inicial bcrypt entregada fuera de la API o restablecimiento controlado; no se ha ensayado contra una fuente sanitizada. No se deben migrar hashes de Supabase sin validar su formato, origen y mecanismo de recuperación.

## Diferencias contractuales conocidas

- Next ya no tiene rutas `/api` serverless ni Supabase: reenvía `/api/**` a Spring con rewrites exactos (sesión por cookie HttpOnly y CSRF de Spring).
- Los DTO conservan el envelope `ok/data/error` cuando la referencia lo exige; las diferencias de validación inseguras identificadas por T-01 no se deben reproducir solo para obtener paridad.
- Las URLs firmadas, archivos DOCX/XLSX/PDF y exportaciones se comparan por contenido, permiso y vigencia, no por token, fecha ni bytes de ZIP.

## Condiciones pendientes para el corte productivo

1. Ensayo de migración con fixture sintético desde el esquema Supabase: comparar UUID/FK/versiones/recuentos/checksums de archivos y probar rollback.
2. Estrategia de cuentas y contraseñas aprobada y ensayada con el responsable institucional, sin exponer secretos ni tocar datos reales.
3. Volumen institucional acordado y repetición de `scripts/load-mixed.sh` en el hardware de despliegue.

Hasta cumplirlas, el backend sirve para integración y validación con datos sintéticos, pero no reemplaza todavía a la instalación institucional.

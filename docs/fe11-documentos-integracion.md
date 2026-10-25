# Documentos privados · extensión de integración FE-11

Validación local: 2026-10-25. UC-11, BE-11 y RF-17.

Flyway V49 agrega `listar_documentos_encuentro_propio(uuid)` y serializa la preparación de cargas con el cierre de la atención mediante bloqueo de su fila. `GET /api/medical/documents?encounterId=...` devuelve metadatos de documentos AVAILABLE de la atención propia, conserva null y ordena por fecha/id descendentes. El médico ajeno recibe 404; otros roles no clínicos, 403.

El POST conserva multipart/201/data.id y los tipos de referencia. Comprueba tamaño real y firma de contenido, además del SHA-256 persistido. Fecha inválida devuelve 400; exceso multipart, 413 con error de texto. Los errores de permiso controlados no terminan en un 500.

La firma conserva data.url relativa y vigencia de 60 segundos. El contenido revalida el acceso vigente y consume un token ligado al actor/documento, de un uso. Un intento ajeno no invalida el enlace del propietario. Las respuestas privadas usan no-store; el binario conserva MIME/nombre original, nosniff y no-referrer. Se auditan listado y acceso al contenido sin texto clínico.

La integración detectó un rechazo CSRF antes de informar sesión expirada: `X-Error-Code` permite al cliente distinguir CSRF_INVALID y renovar una vez, conservando exactamente el JSON de texto heredado. Un rechazo FORBIDDEN de permisos no se reintenta.

Validación: 114 pruebas Java con cero fallos, errores u omitidas; incluye bloqueo concurrente carga/cierre, rollback de contenido/tamaño inválidos, listado, null, permisos y contratos HTTP. Chromium FE-11 y regresión FE-10 pasaron. Se verificaron tamaño y checksum de 11 archivos físicos contra PostgreSQL y una auditoría de carga por archivo, con el actor correcto.

[Informe frontend, escenarios y comandos reproducibles](../../salud-u/docs/evidencia-fe11.md). OpenAPI publicado: `src/main/resources/static/openapi/salud-u-v1.yaml`.

# Contrato de JSON clínico en español

Desde Flyway V47/V48, `datos` de antecedentes, revisión y especialidad se persiste y devuelve con claves/opciones clínicas en español. El diccionario completo es `src/main/resources/clinical-json-dictionary.json`; su copia frontend se compara automáticamente. Los normalizadores aceptan alias heredados de entrada y rechazan claves equivalentes duplicadas. Las respuestas clínicas son canónicas en español.

Se conservan rutas, envoltorios y metadatos HTTP existentes. Por ejemplo, `reviewHistory` contiene `versionEsquema`, `antecedentesPersonales`, `habitos`, `signosVitales`, `examenFisico`, `laboratorio`, `conducta` y `observaciones`. Los antecedentes usan entradas `estado/elementos`; especialidad, `codigoEspecialidad/oftalmologia/ginecologia`. OpenAPI documenta los cambios.

Los textos libres, null, números, fechas, listas y códigos externos de catálogo conservan su contenido. Los códigos de rol y estado de columnas relacionales no forman parte de este cambio. Las plantillas mantienen las palabras reservadas JSON Schema; se traducen nombres/opciones de campos conocidos y `required`.

V47 comprueba reversibilidad al migrar, sin cambiar UUID, versiones, autoría o fechas. Los cierres siguen siendo atómicos y el runtime no obtiene permisos UPDATE/DELETE sobre versiones históricas. V48 conserva la semántica JSON Schema. No se modifican las migraciones históricas ni los fixtures T-01 de referencia.

Validación local del 2026-10-24: 111 pruebas Java aprobadas, regresión Chromium FE-03/10 y controles frontend. Se verificaron 16 versiones existentes antes/después mediante `scripts/verificar-json-clinico.py`; se conservó un respaldo sintético previo en `/tmp/salud-u-antes-json-es.dump`.

[Informe de integración, ejemplos y comandos](../../salud-u/docs/json-clinico-espanol.md).

# Exportaciones clínicas · BE-22 / FE-22

El archivo se solicita con `POST /api/reports/clinical/export`: finalidad obligatoria, formato CSV/XLSX/PDF, filtros canónicos y columnas/groupBy opcionales de GET /api/reports/clinical. Requiere cookie y CSRF. No admite rows ni rowCount. Recalcula el alcance vigente y acepta 0..10000 atenciones sin truncar. El POST base conserva el contrato anterior de registro 201/data.id y no genera un archivo.

La generación completa antecede al registro de éxito y a la respuesta binaria. V63 guarda actor/finalidad/filtros/presentación/formato/estado/cantidad/checksum en exportacion_reporte_clinico, sin acceso directo runtime. Sus funciones exigen rol exportador y la consulta de constancia exige al solicitante. El evento de auditoría evita los valores clínicos de filtros.

Un fallo de generación revierte/libera la transacción de consulta antes de registrar FAILED en una transacción independiente; no publica un archivo parcial. La persistencia/auditoría fallida impide devolver el attachment. COMPLETED indica archivo generado, sin certificar guardado por el navegador. Cada envío explícito genera un registro independiente.

El binario lleva X-Export-Id, X-Export-Row-Count, X-Content-SHA256, MIME, disposition, no-store/private y nosniff. `GET /api/reports/clinical/exports/{id}` devuelve la procedencia propia sin archivo ni filas. Más detalles en el OpenAPI y la [evidencia de integración](../../../salud-u/docs/evidencia-fe22.md).

Se verifican bytes/contenido/permiso, no identidad de ZIP ni fechas volátiles. Los formatos comparten un modelo de datos; CSV neutraliza fórmulas, XLSX usa cadenas, PDF usa fuentes Unicode embebidas con paginación. Símbolos fuera de esa cobertura rechazan el PDF, conservando los datos para otro formato. Texto extenso continúa sin truncamiento y no aumenta la cantidad lógica de atenciones.

`mvn test -q` incluye contratos HTTP, generación/reapertura, límites y PostgreSQL con rollback/procedencia. `docker compose up --build -d` ejecuta verify con caché Maven de BuildKit. Las pruebas de navegador y sus comandos se conservan en el informe enlazado; el volumen de aceptación institucional continúa en FE-CORTE.

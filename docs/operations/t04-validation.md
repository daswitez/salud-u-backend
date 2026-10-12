# Evidencia de T-04

Fecha de preparación: 2026-10-11.

## Preparado y revisado estáticamente

- `/api/v1` separa los contratos Spring de las rutas Next heredadas; OpenAPI se sirve como recurso estático y los fixtures sintéticos documentan los tres escenarios publicados.
- `ApiEnvelope` conserva `ok/data/error`; `ApiError` añade código, detalles vacíos por defecto y `requestId` para v1.
- CSRF usa repositorio HTTP de sesión. El cliente obtiene el token por HTTP y puede enviar `X-CSRF-TOKEN` al logout; sin él recibe el error JSON `CSRF_INVALID`.
- No hay inserciones de usuarios en Flyway ni autenticación demo. La colección Postman contiene roles solo como consumidores de sesiones reales de BE-01.
- `ApiSessionControllerMvcTest` cubre token CSRF, cookie/sesión, logout, 401 y autoridad simulada; `DatabaseActorContextIntegrationTest` añade cuatro escrituras simultáneas contra PostgreSQL Testcontainers.
- XML, YAML y JSON de Postman/OpenAPI quedan sujetos a la validación disponible en este equipo; la compilación y ejecución Java siguen pendientes de Java/Maven/Docker.

## Ensayo pendiente en entorno con Docker

```bash
mvn verify
docker compose up --build -d
```

Importar la colección Postman, ejecutar primero **Obtener CSRF y sesión HTTP**, luego los dos logout. Confirmar `403/CSRF_INVALID` sin encabezado y `204` con el token y cookie de la misma sesión. Tras BE-01, ejecutar la carpeta correspondiente a cada rol con una sesión real y comprobar las autoridades sin usar usuarios creados automáticamente.

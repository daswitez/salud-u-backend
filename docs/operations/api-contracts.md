# Contratos HTTP base (T-04)

## Alcance y compatibilidad

Spring publica dos superficies. La de compatibilidad `/api/**` conserva las rutas que consume el frontend Next durante la transición; la versión nueva `/api/v1/**` concentra identidad, sesión, perfil y catálogos administrativos. Las rutas de compatibilidad se contrastan con `docs/reference-t01`; sus errores tienen `error` textual. No se deben sustituir por el objeto de error de v1.

En `/api/v1/**` la envoltura estable es:

```json
{"ok": true, "data": {}, "error": null}
```

o, para un error:

```json
{"ok": false, "data": null, "error": {"code": "CSRF_INVALID", "message": "…", "details": {}, "requestId": "…"}}
```

La forma `ok/data/error` permite reutilizar los consumidores que ya conocen ese patrón; el objeto detallado de `error` solo pertenece a v1. Cada historia funcional añade su DTO, fixture sintética y comparación con T-01. Los UUID y tiempos generados se comparan por tipo o con una correspondencia declarada.

## Rutas publicadas

| Método | Ruta | Sesión | CSRF | Resultado |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/security/csrf` | no | no | Crea/recupera token y sesión HTTP, sin caché. |
| GET | `/api/health` | no | no | Estado agregado del backend (`backend`/`UP`); reemplaza el chequeo técnico de Supabase. |
| POST | `/api/v1/auth/login` | no | sí | Valida credenciales y envía la cookie opaca HttpOnly. |
| GET | `/api/me` | sí | no | Conserva la forma heredada `ok/user` y sus cinco campos. |
| GET | `/api/v1/session` | sí | no | Expone sujeto y autoridades de una sesión ya autenticada. |
| POST | `/api/v1/session/logout` | no | sí | Invalida la sesión y responde `204`. |
| GET | `/openapi/salud-u-v1.yaml` | no | no | Especificación OpenAPI de estas rutas. |

BE-01 conecta credenciales persistidas, roles vigentes y el principal de Spring. No se crean cuentas, contraseñas, sesiones autenticadas ni datos de demostración al iniciar la aplicación o aplicar Flyway.

## Errores y trazabilidad

| HTTP | Código | Cuándo |
| --- | --- | --- |
| 400 | `INVALID_REQUEST` | JSON o argumentos inválidos. |
| 400 | `VALIDATION_FAILED` | DTO con restricciones de Bean Validation incumplidas. |
| 401 | `UNAUTHENTICATED` | Falta sesión autenticada. |
| 401 | `INVALID_CREDENTIALS` | Credencial incorrecta o límite de intentos aplicado. |
| 403 | `CSRF_INVALID` | Token CSRF inexistente, vencido o distinto. |
| 403 | `FORBIDDEN` | La sesión no satisface la política de la ruta. |

Todas las respuestas pasan `X-Request-Id`; se acepta un valor seguro de ese encabezado o se genera un UUID. Nunca incluir tokens, cookies, contraseñas ni detalles clínicos en `message` o `details`.

## Cliente HTTP y Postman

Importar `docs/postman/salud-u-v1.postman_environment.json` y `docs/postman/salud-u-v1.postman_collection.json`. La primera solicitud obtiene y guarda `csrfToken`; Postman conserva `JSESSIONID` y `SALUD_U_SESSION` en su jar de cookies. La colección prueba login, rechazo CSRF, logout e inspección de sesión por actor. Definir `email` y `password` únicamente para una cuenta real provisionada de forma institucional; no se debe crear un usuario ficticio para cambiar el resultado.

## Evidencia requerida por cada historia posterior

Cada BE-* debe añadir una fixture sintética en `docs/fixtures/<historia>/`, prueba MockMvc de éxito/error/permisos y, si escribe o reserva recursos, una prueba Testcontainers con PostgreSQL y la concurrencia aplicable. La colección Postman se amplía con la ruta publicada, actor permitido, actor rechazado, token CSRF y aserciones de estado/cuerpo.

# Contratos HTTP base (T-04)

## Alcance y compatibilidad

Los contratos heredados de Next permanecen congelados en `docs/reference-t01`: varios responden `{ "ok": true, "data": ..., "error": null }`, mientras que `/api/me` responde `{ "ok": true, "user": ... }` y algunos errores usan un texto plano. No se reescriben ni se publican bajo las mismas rutas en este incremento.

Spring publica únicamente contratos nuevos bajo `/api/v1`. Su envoltura estable es:

```json
{"ok": true, "data": {}, "error": null}
```

o, para un error:

```json
{"ok": false, "data": null, "error": {"code": "CSRF_INVALID", "message": "…", "details": {}, "requestId": "…"}}
```

La forma `ok/data/error` permite reutilizar los consumidores que ya conocen ese patrón; el objeto detallado de `error` solo pertenece a v1. Cada historia funcional añadirá su DTO, fixture sintética y comparación con los casos de T-01 sin modificar la API heredada. Los UUID y tiempos generados se comparan por tipo o con una correspondencia declarada.

## Rutas publicadas

| Método | Ruta | Sesión | CSRF | Resultado |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/security/csrf` | no | no | Crea/recupera token y sesión HTTP, sin caché. |
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

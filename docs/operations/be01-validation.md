# Evidencia de BE-01

Fecha de preparación: 2026-10-11.

## Verificado estáticamente

- V3 no inserta principales, roles ni contraseñas; solo define credenciales, sesiones, RLS, límites de intentos y funciones con privilegio acotado.
- El runtime no recibe `SELECT`, `INSERT`, `UPDATE` ni `DELETE` sobre credenciales o sesiones; solo `EXECUTE` sobre autenticar, resolver y revocar.
- `/api/me` conserva los cinco campos y el error anónimo caracterizado en T-01. Las rutas nuevas se mantienen bajo `/api/v1`.
- OpenAPI, colección/entorno Postman, fixtures sintéticas, XML y YAML son válidos. Los scripts Bash siguen pasando sintaxis.
- `IdentityMvcTest` expresa CSRF, cookie HttpOnly/Secure/SameSite, error genérico y paridad de `/api/me`. La prueba Testcontainers expresa login válido, revocación de rol, cinco fallos secuenciales y cinco concurrentes.

## Pendiente en una máquina con Java, Maven y Docker

```bash
mvn verify
docker compose up --build -d
```

Después de provisionar una cuenta institucional por el proceso aprobado, importar `docs/postman/salud-u-v1.postman_environment.json` y la colección. Ejecutar, en este orden: **Obtener CSRF**, **Login con CSRF**, **Inspeccionar sesión** del rol, **Logout con CSRF**, e inspección posterior (`401`). Repetir con el rol revocado y verificar que `/api/me` devuelve la forma heredada `401/unauthenticated`.

Este entorno no tiene Java, Maven, Docker ni PostgreSQL, por lo que no se declara aprobada la ejecución de MockMvc, Testcontainers ni Flyway real.

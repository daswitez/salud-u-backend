# Evidencia de BE-PER

Fecha de preparación: 2026-10-11.

## Verificado estáticamente

- V5 comprueba la contraseña actual en PostgreSQL, actualiza nombre/correo o bcrypt de contraseña y revoca todas las sesiones activas en la misma transacción.
- El runtime recibe solamente `EXECUTE` sobre las dos funciones; las tablas de identidad siguen protegidas por RLS forzado y sin privilegios directos.
- Los endpoints versionados exigen sesión y CSRF, devuelven `204` sin secretos, y borran la cookie HttpOnly/Secure tras un cambio exitoso.
- `ProfileControllerMvcTest` cubre CSRF, éxito, correo duplicado, contraseña actual incorrecta y borrado de cookie. `DatabaseActorContextIntegrationTest` cubre PostgreSQL real: revocación de sesiones, correo nuevo, contraseña nueva y auditoría append-only.

## Pendiente de ejecución

En una máquina con Java, Maven y Docker:

```bash
mvn verify
docker compose up --build -d
```

Ejecutar el ensayo de `profile-and-password.md` con una cuenta institucional sintética. Antes de habilitar correo real, validar con la institución si la política temporal de confirmación por contraseña vigente debe reemplazarse por confirmación fuera de banda.

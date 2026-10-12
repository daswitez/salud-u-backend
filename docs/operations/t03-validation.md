# Evidencia de T-03

Fecha de preparación: 2026-10-11.

## Verificado en este entorno

- La configuración declara credenciales distintas para migrador y runtime; Spring usa runtime y Flyway usa migrador.
- Las migraciones crean el esquema `salud_u`, UUID, claves foráneas, `timestamptz`, `jsonb`, RLS forzado y un evento de auditoría de solo adición para el runtime.
- El script de inicialización crea el runtime con `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE`, `NOINHERIT` y `NOBYPASSRLS`.
- XML/YAML y sintaxis Bash son válidos. La prueba Testcontainers declara los escenarios de privilegios, RLS y fuga de contexto de conexión.
- La verificación de plataforma ya cuenta automáticamente las migraciones presentes, de modo que conserva validez cuando se agrega V2.

## Pendiente de ejecución externa

Este equipo no tiene Java, Maven, Docker ni PostgreSQL. Faltan ejecutar contra PostgreSQL 17 real:

```bash
mvn verify
./scripts/verify-platform.sh
```

La primera orden debe demostrar que el runtime no tiene `rolbypassrls`, no puede escribir directamente en `audit_event`, no puede ver auditoría sin `AUDITOR` y pierde `salud_u.actor_id` después de commit/rollback. La segunda debe confirmar que Flyway aplica las migraciones con las dos credenciales dentro de Docker.

Antes de usar una base con datos, validar la rotación de roles y respaldos. El cambio de `.env` no modifica roles de un volumen PostgreSQL ya inicializado.

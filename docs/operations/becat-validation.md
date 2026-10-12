# Evidencia de BE-CAT

Fecha de preparación: 2026-10-11.

## Verificado estáticamente

- V4 crea catálogos, personal y vigencias sin datos iniciales, con UUID, FKs, UTC, RLS forzado y bajas lógicas.
- Los permisos del runtime son solo `EXECUTE` sobre funciones concretas; no hay permisos de tabla para credenciales, sesiones ni los catálogos nuevos.
- Las rutas heredadas de lectura conservan campos y orden de T-01; los contratos de administración usan `/api/v1/admin`.
- Se prepararon pruebas MockMvc por rol/CSRF y escenarios Testcontainers de autorización de PostgreSQL y baja lógica.

## Pendiente de ejecución

En una máquina con Java, Maven y Docker:

```bash
mvn verify
docker compose up --build -d
```

Provisionar un administrativo institucional, obtener CSRF, ejecutar creación/desactivación de una especialidad y comprobar que no aparece en `GET /api/specialties`, pero que su fila y las asignaciones históricas continúan en PostgreSQL con el usuario migrador. Repetir con un estudiante para comprobar `403` sin cambios.

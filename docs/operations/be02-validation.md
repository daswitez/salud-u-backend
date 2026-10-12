# Evidencia de BE-02

Fecha de preparación: 2026-10-11.

## Verificado estáticamente

- V6 crea pacientes, matrículas e historia longitudinal con UUID, fechas UTC, FKs, RLS forzado e índices únicos normalizados.
- El runtime solo ejecuta las funciones de lectura/escritura autorizadas; no tiene permisos directos sobre tablas de pacientes.
- `PatientControllerMvcTest` cubre listado compatible, CSRF, alta `201`, colisión `409` y actor no administrativo.
- `DatabaseActorContextIntegrationTest` prepara PostgreSQL real para normalización, una historia única, conservación de UUID, matrícula activa y ausencia de privilegios directos.

## Pendiente de ejecución

En una máquina con Java, Maven y Docker:

```bash
mvn verify
docker compose up --build -d
```

Ejecutar el ensayo de `patients.md`, incluyendo dos altas concurrentes con el mismo carnet y código para confirmar que una transacción obtiene `201` y la otra `409`.

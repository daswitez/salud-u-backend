# Evidencia de BE-04

Fecha de preparación: 2026-10-11.

## Verificado estáticamente

- V7 define jornadas, bloqueos y cupos con RLS forzado, FKs, índices de consulta y funciones transaccionales con zona `America/La_Paz`.
- La generación está limitada a 90 días; detecta bloqueos y solapamientos, y no modifica cupos con reservas al sustituir jornadas o gestionar bloques.
- `AvailabilityControllerMvcTest` cubre CSRF, sustitución, contrato `manage=true` y prohibición para administración.
- `DatabaseActorContextIntegrationTest` prepara PostgreSQL real para generación local, bloqueo de día completo, preservación de cupo reservado y permisos del runtime.

## Pendiente de ejecución

En una máquina con Java, Maven y Docker:

```bash
mvn verify
docker compose up --build -d
```

Ejecutar el ensayo de `availability.md`, incluyendo dos peticiones simultáneas que intenten publicar franjas solapadas y el flujo de reserva de BE-07 antes de sustituir las jornadas.

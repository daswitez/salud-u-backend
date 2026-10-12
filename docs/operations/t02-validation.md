# Evidencia de T-02

Fecha de preparación: 2026-10-11.

## Verificado en este entorno

- XML del proyecto Maven y YAML de `compose.yaml`, `compose.production.yaml` y `application.yml` son válidos.
- Los tres scripts (`backup.sh`, `restore.sh`, `verify-platform.sh`) pasan validación sintáctica de Bash y son ejecutables.
- `backup.sh` rechaza un archivo de entorno inexistente antes de llamar a Docker.
- `restore.sh` rechaza una restauración sin `--confirm-restore` antes de acceder a Docker o al dump.
- `verify-platform.sh` rechaza un equipo sin Docker antes de crear recursos persistentes.
- El backend y la carpeta `codigo` no contienen `.git`.

## Pendiente de ejecución externa

Este equipo no tiene `java`, `mvn`, `docker`, `docker compose`, `psql`, `pg_dump` ni `pg_restore`. Por tanto no se ha afirmado como aprobado lo siguiente:

- `mvn verify` dentro de la imagen.
- Construcción de la imagen y arranque de PostgreSQL 17/Flyway.
- Health/readiness en ejecución.
- Persistencia de los dos volúmenes tras reinicio.
- Dump y restauración reales.
- Obtención y renovación de certificado TLS con DNS institucional.

Para completar la evidencia, ejecutar `./scripts/verify-platform.sh` en una máquina con Docker Engine y Compose v2. Guardar únicamente la salida final, versión de Docker e imagen, sin `.env`, contraseñas, cookies ni el dump. Para TLS, seguir el procedimiento de `platform-and-recovery.md` después de que el dominio institucional apunte al servidor.

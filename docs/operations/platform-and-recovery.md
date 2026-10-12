# Plataforma, TLS y recuperación

## Verificación reproducible de T-02

La comprobación completa se ejecuta en un proyecto Docker aislado, con una contraseña aleatoria efímera y puertos locales `15432` y `18080`. No reutiliza `.env`, no necesita datos reales y elimina sus volúmenes al terminar.

```bash
./scripts/verify-platform.sh
```

El script construye la imagen, por lo que su `mvn verify` debe terminar correctamente. Después confirma que todas las migraciones Flyway presentes se aplican en una base vacía, `GET /actuator/health/readiness` con estado `UP`, persistencia de PostgreSQL y del repositorio privado tras detener/levantar contenedores, y un ciclo real de respaldo/restauración. La restauración usa la tabla efímera `salud_u.t02_restore_probe`; esta se crea únicamente en el proyecto de prueba y desaparece al final.

No ejecutar el script contra el proyecto de producción. Requiere Docker Engine, Docker Compose v2, `curl` y `openssl`.

## Operación local

```bash
cp .env.example .env
# Cambiar DB_MIGRATOR_PASSWORD y DB_APP_PASSWORD por contraseñas únicas.
docker compose up --build --detach
curl --fail http://127.0.0.1:8080/actuator/health
curl --fail http://127.0.0.1:8080/actuator/health/readiness
```

El perfil local publica PostgreSQL y la API solamente en loopback. `SESSION_COOKIE_SECURE=false` se usa únicamente si se accede por HTTP local; para cualquier entorno con usuarios debe permanecer en `true`.

## Respaldo y restauración

`scripts/backup.sh` genera un respaldo PostgreSQL en formato custom dentro de `backups/` con permisos de archivo restringidos. El repositorio privado de documentos es un volumen distinto y debe respaldarse junto con PostgreSQL; una restauración clínica consistente requiere ambos artefactos del mismo instante.

```bash
./scripts/backup.sh
# La restauración es destructiva y exige confirmación explícita.
./scripts/restore.sh backups/salud-u-AAAAmmddTHHMMSSZ.dump --confirm-restore
```

La restauración detiene solamente el servicio backend del proyecto elegido, cierra conexiones a su base, recrea la base y aplica el dump. Antes de una restauración institucional: poner el sistema en mantenimiento, crear y verificar un respaldo nuevo de base y documentos, detener accesos de usuarios, probar primero en un servidor aislado y registrar responsable, fecha y resultado. Después, confirmar readiness, versión Flyway y acceso autorizado a un documento de prueba.

Los scripts respetan `SALUDU_PROJECT` y `SALUDU_ENV_FILE` para operar otra instancia. Solo usar esos valores cuando el nombre de proyecto y archivo fueron revisados; ambos permiten apuntar a un entorno distinto.

## Despliegue con TLS

`compose.production.yaml` despliega PostgreSQL y backend en la red interna, y Caddy publica únicamente HTTPS/HTTP para redirigir y obtener certificados. No expone puertos de PostgreSQL ni del backend. El backend interpreta correctamente cabeceras reenviadas y sus cookies permanecen seguras.

Antes de iniciar:

1. Configurar DNS de `PUBLIC_DOMAIN` hacia el servidor y permitir conexiones entrantes 80/443.
2. Crear `.env` con `DB_MIGRATOR_PASSWORD` y `DB_APP_PASSWORD` únicos, `PUBLIC_DOMAIN` real y `TLS_EMAIL` administrado. Cambiar también `DB_NAME`, `DB_MIGRATOR_USER` y `DB_APP_USER` si la institución lo requiere.
3. Mantener `.env`, volúmenes `postgres_data`, `clinical_documents`, `caddy_data` y `caddy_config` en almacenamiento respaldado. Caddy necesita conservar sus volúmenes para renovar certificados.
4. Ejecutar `docker compose -f compose.production.yaml up --build --detach` y comprobar `https://PUBLIC_DOMAIN/actuator/health` desde la red autorizada.

El health endpoint es técnico y no debe exponerse a Internet sin la política institucional correspondiente. La autenticación, control de acceso clínico, limitación de intentos y auditoría todavía pertenecen a las historias siguientes; TLS no convierte esta base en producción clínica terminada.

## Parámetros operativos

| Variable | Entorno | Finalidad |
| --- | --- | --- |
| `DB_NAME`, `DB_MIGRATOR_USER`, `DB_MIGRATOR_PASSWORD`, `DB_APP_USER`, `DB_APP_PASSWORD` | todos | Base y credenciales separadas de migración y ejecución; contraseñas obligatorias. |
| `DB_PORT`, `BACKEND_PORT` | compose local | Puertos de loopback; no se usan en producción. |
| `SERVER_PORT`, `DB_URL`, `DOCUMENTS_ROOT` | backend | Sobrescriben puerto, JDBC y ubicación privada de archivos. |
| `SESSION_COOKIE_SECURE` | backend | Debe ser `true` salvo desarrollo HTTP local. |
| `PUBLIC_DOMAIN`, `TLS_EMAIL` | producción | Dominio y correo para certificados Caddy. |
| `SALUDU_PROJECT`, `SALUDU_ENV_FILE` | scripts | Seleccionan instancia para respaldo/restauración; revisar antes de ejecutar. |

## Evidencia y límites de esta ejecución

El registro de una ejecución de `verify-platform.sh` debe incluir fecha, versión de imagen, salida final, versión de Flyway, resultado de readiness y ubicación segura del dump de prueba, sin imprimir contraseñas ni cookies. Hasta ejecutar el script en una máquina con Docker, no se puede afirmar que la imagen se construyó ni que PostgreSQL/Flyway/restauración funcionaron en este entorno.

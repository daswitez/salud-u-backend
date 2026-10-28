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

Después de restaurar base y documentos, ejecutar `scripts/reconcile-documents.sh` (sólo lectura) antes de reabrir el servicio: debe terminar en `CONCILIADO`, sin filas sin archivo, checksums distintos, archivos sin fila, temporales ni cargas `PROCESSING`. Una carga cuyo commit falla borra su archivo; si el proceso se interrumpe entre el archivo y el commit puede quedar un archivo sin fila, que este informe detecta.

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

## Copias cifradas y política de recuperación propuesta (RNF-12)

La copia de PostgreSQL puede cifrarse directamente durante la generación con GnuPG y AES-256. La frase de paso debe estar en un archivo externo al repositorio, legible solo por quien ejecuta el respaldo; no se pasa como argumento ni se escribe en el log. Protegerla también con el gestor institucional de secretos y disponer de un procedimiento de recuperación de la clave. La pérdida de la clave impide restaurar las copias cifradas.

```bash
# Archivo de clave ya creado de forma segura fuera del repositorio, modo 600.
export SALUDU_BACKUP_KEY_FILE=/ruta/segura/clave-respaldo
./scripts/backup.sh backups/ --encrypt
./scripts/restore.sh backups/salud-u-AAAAmmddTHHMMSSNNNNNNNNNZ.dump.gpg --confirm-restore
```

El volcado fluye directamente de `pg_dump` a `gpg`, sin escribir un dump sin cifrar en el disco del host. La restauración valida la clave, la integridad y el formato antes de detener el backend o reemplazar la base, y después vuelve a descifrar en flujo para `pg_restore`. La copia y la restauración conservan los permisos SQL, que son necesarios para el rol de ejecución. El modo sin `--encrypt` sigue disponible para pruebas y produce un archivo sin cifrar, que no satisface la política propuesta de copias institucionales. Una restauración puede fallar después de comenzar por falta de espacio u otros errores: conservar el respaldo previo y comprobar readiness, conteos y permisos.

Propuesta **3-2-1**, pendiente de aprobación y puesta en marcha institucional:

- Mantener al menos tres copias: datos operativos y dos respaldos verificables, en al menos dos soportes independientes.
- Ejecutar una copia diaria cifrada de la base y una copia coordinada y cifrada del volumen de documentos clínicos. Propuesta de retención: 7 diarias, 4 semanales y 12 mensuales, sujeta a requisitos institucionales.
- Guardar al menos una copia cifrada fuera del sitio físico, con control de acceso, gestión separada de claves y prueba periódica de restauración. No se ha configurado ni verificado una copia externa en este ensayo.
- **RPO propuesto: hasta 24 horas**, igual a la frecuencia diaria, siempre que la última copia se haya completado y validado; no constituye una medición de pérdida real ni una garantía ante fallos de la programación.

### Medición local del 27/10/2026

Con tres copias cifradas de una base PostgreSQL 17 sintética de 500 pacientes y 1.500 atenciones, en la instancia desechable `salud-u-recuperacion`, la copia tardó en promedio **0,236 s** y como máximo **0,251 s**, con tamaño medio **545.760 bytes** y máximo **546.046 bytes**. El tiempo desde iniciar `restore.sh` hasta readiness HTTP 200/UP fue **8,912 s de media y 8,969 s de máximo**. En las tres iteraciones coincidieron los conteos de 59 tablas; un inicio de sesión y una consulta autorizada de ficha respondieron HTTP 200 después de cada restauración.

Este es el **RTO medido de la base hasta readiness en ese entorno y volumen**, no el RTO integral institucional: no incluye obtener la copia fuera del sitio, restaurar/reconciliar documentos, el frontend, validaciones adicionales, coordinación humana ni un corte real. Se necesita medir con el volumen objetivo y ambos artefactos antes de fijar un compromiso operativo. Detalle, entorno, comandos y límites: `../../../../ENTREGAS_CODEX/REC-RESTAURACION/resumen.md`.

## HTTPS para red local sin dominio público (SEG-TLS)

`Caddyfile.lan` y `compose.lan-tls.yaml` crean una puerta de entrada con CA interna de Caddy. En Linux usa la red del host para llegar por loopback al frontend y al backend de la misma máquina. El proceso Next debe escuchar **solo** `127.0.0.1:3000`, el backend `127.0.0.1:8080` y PostgreSQL no debe publicarse en la LAN. Todo el tráfico web del cliente pasa por Caddy: Next reenvía las API a Spring, y las rutas de readiness se reenvían al backend. Esto requiere haber compilado Next con `SALUD_U_BACKEND_ORIGIN=http://127.0.0.1:8080` y mantener `SESSION_COOKIE_SECURE=true` en el backend. El archivo LAN es independiente de `compose.production.yaml`; no lo mezcle con el perfil de producción que no publica el backend en el host sin adaptar su conectividad.

El valor predeterminado escucha solo en `127.0.0.1`, HTTP 8088 y HTTPS 8443. Para una instalación LAN, configurar `SALUDU_LAN_BIND` con la IP local del servidor y `SALUDU_LAN_HOST` con esa IP o con un nombre interno que resuelva a ella; ajustar puertos y cortafuegos. Un nombre interno, por ejemplo bajo un dominio privado controlado por la institución, permite que los navegadores apliquen HSTS; con direcciones IP el encabezado se envía pero no se debe asumir que el navegador lo aplique. Mantener el nombre o IP usado en la URL igual al incluido en el certificado.

```bash
# Ejemplo: sustituir por la IP y nombre internos autorizados.
export SALUDU_LAN_BIND=192.168.10.10
export SALUDU_LAN_HOST=salud.interna.example
export SALUDU_HTTP_PORT=8088 SALUDU_HTTPS_PORT=8443
docker compose -f compose.lan-tls.yaml -p salud-u-lan up -d
# Extraer solo el certificado público de la CA; nunca distribuir la clave privada.
docker compose -f compose.lan-tls.yaml -p salud-u-lan cp caddy:/data/caddy/pki/authorities/local/root.crt ./ca-interna-publica.crt
SALUDU_CA_FILE=./ca-interna-publica.crt scripts/security/verify-lan-tls.sh
```

El administrador debe verificar la huella y distribuir el certificado público de la CA a cada equipo cliente mediante el mecanismo institucional de confianza. No instalarlo automáticamente ni usar `curl -k` como validación de identidad; la prueba usa `--cacert` y `openssl -verify_return_error`. El volumen de Caddy contiene la clave privada de la CA: protegerlo y respaldarlo; si se pierde o cambia, se necesita redistribuir la nueva CA. Caddy usa `tls internal`, mínimo TLS 1.2 y máximo 1.3, redirección 301 y HSTS `max-age=31536000`. [Documentación oficial de HTTPS local de Caddy](https://caddyserver.com/docs/automatic-https) y [directiva TLS](https://caddyserver.com/docs/caddyfile/directives/tls).

**Alcance:** TLS protege el tramo cliente–Caddy. Caddy–Next y Next–Spring se conectan por HTTP en loopback; Spring–PostgreSQL usa la red Docker local sin TLS en esta configuración. No se ha demostrado cifrado de todos los enlaces internos. Si un componente se mueve a otro host, configurar TLS y validación de certificados también en ese enlace antes de enviar datos por la red. No hay exposición directa del backend o Next en la LAN cuando se mantienen las restricciones anteriores.

### Ensayo SEG-TLS del 27/10/2026

En una pila de demostración aislada se probó la dirección LAN `192.168.1.11`, HTTP 18088 y HTTPS 18443. Desde el host y un contenedor de otra red se verificaron la cadena de la CA y el certificado para esa IP. Se negociaron TLS 1.2 y 1.3, y el servidor rechazó TLS 1.1 con alerta de versión. La página respondió 200, HTTP redirigió a HTTPS, se observaron HSTS, CSP, X-Frame-Options y nosniff, y una sesión administrativa sintética funcionó con cookie `Secure`, `HttpOnly`, `SameSite=Lax`. Esto no sustituye una prueba desde cada equipo físico de la institución ni la instalación de la CA en sus almacenes. [Evidencia SEG-TLS](../../../../ENTREGAS_CODEX/SEG-TLS/resumen.md).

## Cifrado en reposo propuesto para base y documentos

Recomendación: preparar un **dispositivo dedicado nuevo** con LUKS2/dm-crypt en el host, montarlo antes de arrancar la pila y guardar allí tanto PostgreSQL como `clinical_documents`. No se ha creado ni desbloqueado un volumen LUKS en este equipo; los pasos siguientes son un procedimiento propuesto para la instalación. Acordar ventana de mantenimiento, inventariar rutas actuales, detener escrituras y verificar una copia y restauración de base **y** documentos antes de migrar. `luksFormat` destruye el acceso a los datos que ya estén en el dispositivo seleccionado: verificar con el responsable que sea el dispositivo nuevo, no usar una ruta de ejemplo literalmente.

1. En el dispositivo nuevo confirmado, crear LUKS2, abrirlo como `salud-u-datos`, crear un sistema de archivos y montarlo en `/srv/salud-u-cifrado`. Por ejemplo, sustituyendo `<DISPOSITIVO_NUEVO>` únicamente después de identificarlo:

   ```bash
   sudo cryptsetup luksFormat --type luks2 <DISPOSITIVO_NUEVO>
   sudo cryptsetup open <DISPOSITIVO_NUEVO> salud-u-datos
   sudo mkfs.ext4 /dev/mapper/salud-u-datos
   sudo mkdir -p /srv/salud-u-cifrado
   sudo mount /dev/mapper/salud-u-datos /srv/salud-u-cifrado
   sudo cryptsetup status salud-u-datos
   findmnt /srv/salud-u-cifrado
   ```

2. Preparar directorios `postgres/` y `documentos/` dentro del montaje, con propietarios y permisos adecuados para las imágenes realmente desplegadas. En las imágenes probadas el usuario PostgreSQL es UID/GID 999 y el backend UID/GID 10001; verificarlo para cada imagen y considerar user namespaces. Restaurar el dump validado y la copia coordinada de documentos en el volumen cifrado durante mantenimiento; no copiar un directorio PostgreSQL en caliente. Conservar la copia original hasta comprobar restauración y conciliación.
3. Como diseño de despliegue, un override Compose puede reemplazar por destino `/var/lib/postgresql/data` y `/var/lib/salud-u/documents` con bind mounts bajo `/srv/salud-u-cifrado/postgres` y `/srv/salud-u-cifrado/documentos`, respectivamente; emplear `create_host_path: false` y deshabilitar reinicios automáticos de esos contenedores hasta establecer una unidad de arranque que desbloquee y verifique el montaje. Un directorio que exista sin el volumen montado **no** garantiza cifrado. Antes de cada arranque comprobar `mountpoint -q /srv/salud-u-cifrado`, `cryptsetup status salud-u-datos` y el origen con `findmnt`; el servicio debe fallar cerrado si no está montado. Revisar el Compose resuelto para confirmar que ambos destinos apuntan al volumen cifrado y que no siguen usando volúmenes anteriores.
   Ejemplo de override para una **pila detenida**; guardar con permisos restringidos fuera del código como `compose.cifrado.yaml` y adaptar la ruta. La fusión de Compose reemplaza los mounts por su destino; comprobarlo en la configuración resuelta antes de iniciar:

   ```yaml
   services:
     postgres:
       restart: "no"
       volumes:
         - type: bind
           source: /srv/salud-u-cifrado/postgres
           target: /var/lib/postgresql/data
           bind:
             create_host_path: false
     backend:
       restart: "no"
       volumes:
         - type: bind
           source: /srv/salud-u-cifrado/documentos
           target: /var/lib/salud-u/documents
           bind:
             create_host_path: false
   ```

   Para la pila de ejemplo local, seleccionar ambos archivos mediante `COMPOSE_FILE=compose.yaml:/ruta/segura/compose.cifrado.yaml`, verificar el proyecto con `SALUDU_PROJECT`, y usar esa misma configuración en todas las operaciones de copia y restauración. Antes de `up`, un supervisor debe comprobar el montaje LUKS; `create_host_path: false` solo verifica que las carpetas existan, no que estén cifradas. Si se reutilizan contenedores con políticas `restart` previas, recrearlos durante la ventana de mantenimiento después de verificar el override.

4. Verificar `lsblk -f`, `cryptsetup status`, `findmnt` y los mounts del contenedor; iniciar la pila solo después de desbloquear y verificar la unidad. Comprobar readiness, inicio de sesión y ficha, restauración de un documento de prueba y `scripts/reconcile-documents.sh`. Repetir tras un reinicio controlado. Separar claves del repositorio y del respaldo; guardar respaldo del encabezado LUKS y de las claves con custodia institucional y probar su recuperación. El [FAQ oficial de cryptsetup](https://gitlab.com/cryptsetup/cryptsetup/-/blob/main/FAQ.md) describe el respaldo del encabezado; los [bind mounts de Docker](https://docs.docker.com/engine/storage/bind-mounts/) pueden ocultar datos previos del destino y deben verificarse.

LUKS protege los datos en reposo cuando el dispositivo está bloqueado; no sustituye control de acceso a un sistema desbloqueado. La copia cifrada de base de REC-RESTAURACION se probó con GPG; el cifrado y la restauración de copias del volumen de documentos y el almacenamiento externo **siguen pendientes**. Tampoco se ha implantado o verificado cifrado en reposo de PostgreSQL y documentos del host real.

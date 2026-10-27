# N-03 · Recordatorios programados

Fecha de cierre: **27 de octubre de 2026**, America/La_Paz. **Terminada y aplicada localmente**, Flyway V84. Trazabilidad: RN-36; PV-7.2. Depende de N-01/N-02. Sin SMTP; recordatorio reforzado diferido hasta O-03.

## Comportamiento

`NotificationReminderJob` ejecuta `NotificationReminderService` mediante `@Scheduled`. Tanto el registro del programador como el trabajo requieren `salud-u.scheduling.enabled=true`. Sin la propiedad o con false no existe ninguna tarea registrada. El servicio abre una transacción y llama a `salud_u.generar_recordatorios_citas()`.

Por defecto corre cada 15 minutos (`0 */15 * * * *`), con zona `America/La_Paz`. Cada ejecución calcula mañana con la fecha de Bolivia y selecciona el intervalo desde su medianoche inclusive hasta la siguiente medianoche exclusiva, independientemente de la zona horaria de la sesión PostgreSQL. Solo incluye citas PROGRAMADA, pacientes con cuenta vinculada y preferencias `recibir_recordatorios=true`. La ausencia de preferencias equivale a true, conforme a N-02.

Entrega un aviso RECORDATORIO_CITA, canal BANDEJA, estado ENTREGADA. Asunto «Recordatorio de cita» y mensaje con fecha/hora de Bolivia, sin contenido clínico. La entrega ocurre al ejecutar el trabajo; no se promete exactamente 24 horas antes. Una cita creada durante el día para mañana se recoge en la próxima ejecución.

`recordatorio_reforzado` queda almacenado por N-02, pero no interviene en el aviso ordinario. Desactivar `recibir_recordatorios` evita nuevas entregas; conserva los avisos históricos. No hay recuperación retrospectiva de días en que el servicio estuvo apagado.

> **Actualización O-03 (V88):** el recordatorio reforzado ya está activo. Se envía el día de la cita, desde las 07:00, cuando la asistencia estimada es menor al 70 % y `recordatorio_reforzado` está activo. Ver [O-03](o03-estimaciones-de-asistencia-y-demanda.md).

## Idempotencia y concurrencia

Se conserva el índice único `(tipo_evento,id_cita,id_destinatario,canal)`. Una cita tiene como máximo un RECORDATORIO_CITA por destinatario. Los reintentos sin cambios conservan ID, fecha de entrega, estado leído y fecha de lectura. Cuando cambia el horario o el día objetivo y la cita es elegible de nuevo, se actualiza el mismo ID con el horario vigente y vuelve a ENTREGADA sin lectura. Se conserva `creado_en`.

V84 añade `fecha_objetivo date` como dato interno para distinguir el día de cita al que corresponde el recordatorio; un CHECK exige esa fecha solo para RECORDATORIO_CITA. No se añade al contrato HTTP. `scheduledFor` continúa siendo la fecha de entrega programada del aviso, no el horario de la cita.

Los trabajadores bloquean las citas con `FOR UPDATE OF c SKIP LOCKED`; el índice único protege también la inserción. Una fila bloqueada se revisa en otra ejecución. La transacción comprende el lote completo: si falla una inserción, no quedan entregas parciales. El trabajo registra el error y vuelve a intentarlo en el próximo turno.

La función sin parámetros usa `statement_timestamp()` y solo devuelve el número de avisos creados o actualizados. El runtime tiene EXECUTE, sin contexto de usuario web, porque es un trabajo global acotado a mañana. No existe endpoint para dispararlo ni se aceptan fechas, destinatarios o texto externos. El núcleo reproducible `generar_recordatorios_citas_en(timestamptz)` es privado del migrador. Ambas funciones fijan search_path, son SECURITY DEFINER y revocan PUBLIC. Se conservan RLS y permisos de lectura/escritura de N-01/N-02.

## Activación

Configuración de Spring y variables de Compose de desarrollo/producción:

| Propiedad | Variable | Predeterminado |
|---|---|---|
| `salud-u.scheduling.enabled` | `SALUD_U_SCHEDULING_ENABLED` | `false` en `application.yml` y `compose.yaml`; **`true` en `compose.production.yaml`** desde la revisión V85 |
| `salud-u.scheduling.reminder-cron` | `SALUD_U_REMINDER_CRON` | `0 */15 * * * *` |

En producción los recordatorios corren sin configuración adicional; para apagarlos, definir `SALUD_U_SCHEDULING_ENABLED=false` en `.env`. Varias instancias pueden correrlo a la vez: `SKIP LOCKED` y el índice único evitan duplicados.

Desde V85, un recordatorio solo se muestra mientras su cita sigue `PROGRAMADA` para la fecha que anuncia. Si la cita se cancela, se marca ausente, se atiende o pasa a otro día, el aviso deja de aparecer en la bandeja y en el contador, y marcarlo como leído responde 404. No se borra: si la cita vuelve a quedar para mañana, la siguiente ejecución lo actualiza y lo entrega de nuevo. [Revisión V85](revision-v85-permisos-y-notificaciones.md).

Para habilitarlo en desarrollo, definir en `.env` o en el entorno de Compose:

```dotenv
SALUD_U_SCHEDULING_ENABLED=true
SALUD_U_REMINDER_CRON="0 */15 * * * *"
```

Después, desde el backend:

```bash
docker compose up -d backend
docker compose logs --since=30m backend
```

Compose recrea el contenedor al cambiar el entorno. Para detener el trabajo, usar false y recrear. El cron tiene seis campos de Spring. Los cambios se aplican al iniciar el backend. Las ejecuciones con cambios registran el contador; los fallos dejan un registro de error y se reintentan.

**Estado local al cierre: desactivado (`false`)**, cron predeterminado confirmado. No se modificó `.env`. La ejecución real del programador se verificó en pruebas con servicio simulado, sin habilitarlo sobre los datos existentes.

## Validación y aplicación

- Antes: **224 pruebas**. Después: `mvn -B -ntp verify`, **235 pruebas, 0 fallos, 0 errores, 0 omitidas**.
- Siete pruebas nuevas PostgreSQL/Testcontainers: límites inclusivo/exclusivo y zona independiente; estados excluidos y cuenta ausente; preferencias; reintentos conservando lectura; cuatro trabajadores concurrentes; reprogramación; rollback del lote y recuperación; permisos y visibilidad por bandeja propia.
- Cuatro pruebas del programador: apagado por defecto/false, registro de cron configurable, disparo real de `@Scheduled` y continuidad tras error.
- `plpgsql_check`, caracterización completa y pruebas N-01/N-02 aprobadas. Las 18 pruebas específicas (7 recordatorios, 4 programador, 7 esquema) también pasaron por separado.
- OpenAPI incorpora RECORDATORIO_CITA; conserva rutas y campos. YAML de OpenAPI, aplicación y ambos Compose validado.
- Respaldo previo: `backups/salud-u-20261027T041922Z.dump`.
- Docker reconstruido, Flyway **84 / success=true**, salud **UP**. El build sin Docker omite las pruebas Testcontainers; la ejecución del host ejecutó las 235 sin omisiones.
- Inventario inglés **0**, diccionario **96 equivalencias/29 dominios**, sin nuevas excepciones lingüísticas.
- Once definiciones de funciones de agenda/N-01/N-02 idénticas antes/después. Hashes de 460 citas, 3 avisos y 1 preferencia sin diferencias, normalizando únicamente la nueva columna nula `fecha_objetivo`.
- Ensayo local dentro de BEGIN/ROLLBACK: dos citas sintéticas para mañana, una con preferencias desactivadas; generación por runtime sin actor, núcleo privado inaccesible, lectura de bandeja propia, marcado leído, reintento que conserva lectura y exclusión del destinatario desactivado. Todo revertido y hashes previos nuevamente idénticos. Para consultar la bandeja en esa misma transacción se normalizaron solo las dos marcas temporales del aviso sintético a `now()`: la generación usa inicio de sentencia y la bandeja usa inicio de transacción; en funcionamiento normal se consulta en otra transacción posterior.

Logs temporales: `/tmp/n03-antes.log`, `/tmp/n03-pruebas.log`, `/tmp/n03-esquema.log`, `/tmp/n03-despues.log`, `/tmp/n03-docker.log`. Ensayo `/tmp/n03-smoke.sql`; comparación `/tmp/n03-antes.txt` y `/tmp/n03-despues.txt`. Las pantallas permanecen en F-01/F-02; el reforzado se implementará con O-03.

# O-02 · Observación de jornada y cierre nocturno

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V87__observacion_jornada_y_cierre_nocturno.sql`.
Trazabilidad: RN-34, PA-23, PV-7.3.

Consolida cada día lo que pasó en la agenda, como entrada de las estimaciones de O-03. Solo lee agenda y calendario.

## 1. Especialidad de las solicitudes por derivación

Las solicitudes por derivación no guardaban su especialidad: vivía solo en `derivacion`, que es una tabla clínica. Para contar la demanda por especialidad sin leerla, V87:

- copia la especialidad de la derivación en las 52 solicitudes existentes;
- hace que `crear_solicitud_derivacion` la guarde al crear la solicitud;
- agrega el CHECK `solicitud_cita_especialidad_segun_tipo`: solo la revisión inicial va sin especialidad.

La especialidad de una derivación no cambia después de creada, y `asignar_solicitud_cita` ya exigía que el cupo fuera de esa especialidad, así que el dato es coherente. Efecto visible: en `GET /api/appointment-requests`, `specialty_id` de una solicitud `REFERRAL` ahora trae la especialidad en vez de `null`. El campo ya admitía ambos valores y la pantalla de admisión no lo usa para las derivaciones.

## 2. Tabla `observacion_jornada`

Hay dos clases de fila por fecha:

| Fila | `id_personal` | Contenido |
|---|---|---|
| Médico | el médico | Lo que pasó en sus cupos de ese día, por especialidad (NULL = área, la revisión inicial). `solicitudes_ingresadas` es NULL. |
| Especialidad | NULL | La suma de sus médicos, más las **solicitudes ingresadas** ese día. Una solicitud todavía no tiene médico, por eso solo se cuenta aquí. Puede tener capacidad 0: demanda sin oferta. |

Columnas: `fecha`, `id_personal`, `id_especialidad`, `id_periodo_academico` y `tipo_periodo` (el período que contiene la fecha, o ninguno), `capacidad`, `citas_programadas`, `asistencias`, `ausencias`, `sin_registrar`, `cancelaciones`, `solicitudes_ingresadas`, `cerrada_en`, `actualizada_en`.

Cómo se cuenta (el día es el de Bolivia, con un rango semiabierto [00:00, 24:00) sobre `inicia_a` del cupo):

- **capacidad:** cupos `PUBLICADO` y cualquier cupo que llegó a tener una cita no cancelada. Quedan fuera los borradores, los bloqueados y los cerrados sin uso (horarios retirados). La base local tiene cupos `CERRADO` con citas atendidas, de las regresiones antiguas; por eso se cuentan.
- **asistencias:** citas `LLEGADA` o `ATENDIDA`; **ausencias:** `AUSENTE`; **sin_registrar:** siguen `PROGRAMADA` al cerrar; **cancelaciones:** `CANCELADA`.
- **citas_programadas** = asistencias + ausencias + sin_registrar (CHECK). Las canceladas van aparte.
- **solicitudes_ingresadas:** solicitudes con `solicitado_en` ese día, en cualquier estado posterior.

`sin_registrar` no estaba en el backlog. Se agregó para que O-03 use solo asistencias y ausencias confirmadas, sin suponer qué pasó con una cita que nadie marcó.

Restricciones: una fila por (fecha, médico, especialidad) con `UNIQUE NULLS NOT DISTINCT`; RLS forzada solo con la política del migrador; sin permisos para el rol de la aplicación.

## 3. Funciones

**`cerrar_jornada(p_fecha date)`**, privada del migrador.

- Está escrita con cuerpo SQL estándar (`BEGIN ATOMIC`), así PostgreSQL registra en `pg_depend` cada tabla y columna que usa. En plpgsql no quedaría ese registro.
- **Idempotente:** recalcula la fecha, actualiza solo las filas que cambiaron, borra las combinaciones que ya no existen (por ejemplo, un cupo movido a otro día) y devuelve cuántas filas cambió. Repetirla devuelve 0 y conserva los identificadores.
- Solo cierra días pasados de Bolivia: con hoy o una fecha futura no hace nada.

**`cerrar_jornadas_recientes()`**, la entrada del rol de la aplicación, sin parámetros.

- Vuelve a cerrar los siete días anteriores a hoy. Así recoge asistencias o cancelaciones registradas tarde y recupera las noches en que el servidor estuvo apagado.
- Un `pg_advisory_xact_lock` evita que dos instancias cierren a la vez.

**Para O-03:** como un día puede volver a cerrarse durante una semana, la estimación no debe sumar cada cierre como evidencia nueva. Conviene recalcularla desde las observaciones en orden de fecha, que es barato con este volumen (RNF-14).

## 4. Tarea nocturna

`DayCloseJob` en el paquete `scheduling`, detrás de `salud-u.scheduling.enabled`, la misma propiedad de N-03.

- Cron `salud-u.scheduling.day-close-cron`, variable `SALUD_U_DAY_CLOSE_CRON`, por defecto `0 30 0 * * *` (00:30) en `America/La_Paz`.
- Un fallo se registra en el log y se reintenta en la próxima ejecución.
- `compose.production.yaml` la activa por defecto, igual que los recordatorios; `compose.yaml` y `application.yml` la dejan apagada.

## Pruebas y resultados

- `mvn verify`: **249 pruebas**, sin fallos, errores ni omisiones; `plpgsql_check` aprobado; inventario de inglés en cero. Las pruebas ejecutan 120 de las 122 funciones SQL, incluidas las dos nuevas.
- `ObservacionJornadaIntegrationTest` (5 pruebas):
  - **PV-7.3:** un médico con 8 asistencias, 2 ausencias, 1 cancelada y 1 sin registrar; cupos bloqueados, borradores y cerrados sin uso excluidos; un cupo cerrado con cita incluido; límites de medianoche de Bolivia; solicitudes por área y especialidad, incluida una especialidad sin cupos; período `CLASES`.
  - Repetir el cierre devuelve 0 y deja todo igual. Una asistencia tardía cambia exactamente 2 filas. Mover los cupos de un médico borra su fila.
  - Hoy y mañana no se cierran.
  - El rol de la aplicación solo ejecuta `cerrar_jornadas_recientes`, que abarca los siete días anteriores y no el octavo; no puede llamar a `cerrar_jornada` ni leer la tabla.
  - **RN-34 / PA-23:** el conjunto de columnas en `pg_depend` es exactamente el permitido (de `cita` solo `id_cupo` y `estado`). El texto de las dos funciones solo nombra esas tablas y no contiene términos clínicos. La entrada nocturna solo delega en `cerrar_jornada`.
  - El CHECK de especialidad por tipo de solicitud.
- `DayCloseSchedulingTest` (4 pruebas): sin la propiedad no hay tarea; cron por defecto y configurado; ejecución real por `@Scheduled`; un fallo no impide el siguiente intento.

## Ensayo y base local

1. Ensayo sobre una copia de la base local:
   - V87 aplicada y las 52 solicitudes por derivación con especialidad.
   - Los conteos del cierre coinciden con un conteo directo por fecha.
   - `crear_solicitud_derivacion` con una derivación pendiente real copia la especialidad; se deshizo.
2. Respaldo previo: `backups/salud-u-20261027T052626Z.dump`.
3. Backend reconstruido. Flyway aplicó **V87**, la preparación responde 200 y no hay errores ni advertencias en el log.
4. Comprobado sobre la base local:
   - 0 funciones abiertas a PUBLIC; RLS forzada en `observacion_jornada`;
   - `cerrar_jornadas_recientes()` como rol de la aplicación generó 89 observaciones y la segunda llamada 0, dentro de una transacción que se deshizo;
   - el programador local sigue desactivado, así que la tabla está vacía hasta que se active.

# ES-03 · Agenda en español

Fecha: 26 de octubre de 2026. Estado: **terminada**. Migración: `V74__agenda_en_espanol.sql`.

## Qué cambió

| Columna | Antes | Ahora |
|---|---|---|
| `cupo_disponibilidad.estado` | DRAFT, PUBLISHED, BLOCKED, CLOSED | BORRADOR, PUBLICADO, BLOQUEADO, CERRADO |
| `solicitud_cita.estado` | PENDING, ASSIGNED, CANCELLED | PENDIENTE, ASIGNADA, CANCELADA |
| `solicitud_cita.tipo_cita`, `cita.tipo_cita` | INITIAL, SPECIALTY, REFERRAL | INICIAL, ESPECIALIDAD, DERIVACION |
| `solicitud_cita.origin` → **`origen`** | INITIAL, ADMIN_DIRECT | INICIAL, DIRECTA_ADMINISTRACION |
| `cita.estado`, `evento_estado_cita.estado_anterior` y `estado_nuevo` | SCHEDULED, CHECKED_IN, ATTENDED, CANCELLED, NO_SHOW | PROGRAMADA, LLEGADA, ATENDIDA, CANCELADA, AUSENTE |

La migración sigue el orden de la historia, en una sola transacción:

1. Quita los CHECK, los valores por defecto y los tres índices únicos parciales (`WHERE estado = 'PENDING'`), y renombra `origin`.
2. Traduce los datos **con el diccionario** (`desde_codigo_api`). Si aparece un valor que no está en él, la migración entera falla, así que no puede quedar un dato a medio traducir.
3. Recrea los CHECK, los valores por defecto y los índices con nombres en español y la misma semántica. Además agrega dos CHECK que faltaban: `solicitud_cita.origen` y los estados de `evento_estado_cita`.
4. Reescribe las 25 funciones afectadas a partir de su última definición, tomada de la base con `pg_get_functiondef`. `listar_bandeja_derivaciones_administracion` lee `cita`, pero no usa ni devuelve sus códigos, así que no cambió.

## Cómo se tradujeron las funciones

Las funciones se generaron con una lista explícita de reemplazos **por función**, aplicada sobre `pg_get_functiondef`. Cada reemplazo indicaba cuántas veces debía aparecer y fallaba si no coincidía.

- **Reemplazo total** del literal solo en las 8 funciones donde ese literal es siempre de agenda: bloqueos, cupos, llegada, ausencia y cancelación.
- **Reemplazo en contexto** en el resto. Por ejemplo, en `asignar_solicitud_cita`, `SET estado='ASSIGNED',id_cita=…` (solicitud) pasa a `ASIGNADA`, pero `UPDATE salud_u.derivacion SET estado='ASSIGNED'` queda para ES-05.
- **Salidas hacia Java**: estas funciones devuelven códigos de API con `a_codigo_api`:
  - `listar_disponibilidad_publicada`
  - `listar_mi_disponibilidad`
  - `listar_mis_citas_medicas`
  - `listar_mis_solicitudes_cita`
  - `consultar_derivaciones_asignadas`
  - `obtener_contexto_encuentro_propio`
  - `obtener_historia_longitudinal_area`

  Ninguna función de agenda recibe códigos de agenda desde Java: el tipo de solicitud lo decide el controlador eligiendo la función.
- **Copia entre dominios**: `abrir_encuentro_borrador` copiaba `cita.tipo_cita` a `encuentro_clinico.tipo_encuentro`, que sigue en inglés hasta ES-04. Ahora copia `a_codigo_api('tipo_cita', …)`, que da justo `INITIAL` o `SPECIALTY`. En ES-04 vuelve a ser una copia directa.
- Quedan 21 literales en inglés en estas funciones, revisados uno por uno. Todos son de derivación (`ASSIGNED`, `IN_PROGRESS`, `PENDING_ASSIGNMENT`), de encuentro (`DRAFT`, `CLOSED`, `INITIAL` y `SPECIALTY` como `tipo_encuentro`), de química (`PENDING`) o de auditoría (`SUCCESS`).
- Las llamadas a `tiene_rol_actor` de estas 25 funciones pasaron a español (ES-02, tarea 5). Quedan 32 llamadas en inglés, repartidas en 16 funciones.

**Java no cambió.** Los cinco controladores de la historia y `AvailabilityService` solo pasan al frontend lo que devuelven las funciones. Las únicas comparaciones de códigos en Java (`appointmentType` en `AppointmentRequestController`) son sobre el cuerpo de la solicitud HTTP, que sigue en inglés.

## Pruebas y resultados

- `mvn verify` con **198 pruebas aprobadas**.
- `plpgsql_check` sin errores en todas las funciones.
- Cobertura de funciones: 104 de 106.
- Datos de prueba: se tradujeron 55 líneas de `DatabaseActorContextIntegrationTest` que escriben o leen las tablas de agenda directamente. La única línea que mezcla agenda con encuentro (`with nuevas as (insert into salud_u.cita …) insert into salud_u.encuentro_clinico …`) se tradujo a mano, solo en la parte de la cita. Las aserciones sobre respuestas de la API no cambiaron.
- Caracterización de agenda idéntica: `CaracterizacionFlujosIntegrationTest` (solicitud directa, asignación, derivación completa) y los flujos de disponibilidad, asistencia y cancelación de `DatabaseActorContextIntegrationTest`.
- Inventario: la línea base bajó de 531 a **420**. Salieron 111 elementos y no entró ninguno: 18 valores CHECK, 86 literales, 4 restricciones, 2 índices y la columna `origin`. Ya **no queda ningún valor de agenda en inglés**. Lo que sigue en esas tablas son nombres: 3 restricciones, 2 índices, 4 parámetros y 4 políticas, todos para ES-09.

## Ensayo con datos reales

Se hizo sobre una copia de la base local restaurada desde `backups/salud-u-20261027T011438Z.dump`, en V71, aplicando V72, V73 y V74. Las tres se aplicaron sin errores y se recrearon los índices únicos.

**Conteos idénticos uno a uno:**

- 459 citas;
- 606 cupos;
- 385 solicitudes;
- 692 eventos de cita.

Por ejemplo, `ATTENDED/INITIAL` 217 pasó a `ATENDIDA/INICIAL` 217, y `ASSIGNED/REFERRAL/INITIAL` 51 a `ASIGNADA/DERIVACION/INICIAL` 51.

**Salidas idénticas.** Se compararon antes y después, como administración, `listar_mis_solicitudes_cita`, `resumen_administrativo` y `listar_disponibilidad_publicada`, y `listar_mis_citas_medicas` para cada uno de los 63 médicos con citas: **1415 filas, 0 diferencias**.

Las copias se eliminaron; la base local no se tocó.

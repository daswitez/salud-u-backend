# O-06 · Decidir una sugerencia

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V91__decision_de_sugerencias.sql`.
Trazabilidad: RN-33, RF-41, PA-21, PA-22.

## 1. Qué hace cada decisión

`POST /api/scheduling/suggestions/{id}/decision` recibe `{decision, reason, slots}`. Solo ADMINISTRATIVE, con CSRF. La decisión y su efecto se aplican en **una transacción** con `salud_u.decidir_sugerencia_agenda`.

| Tipo | ACCEPTED | MODIFIED | REJECTED |
|---|---|---|---|
| OVERBOOKING (SOBRECUPO) | Sube la capacidad de los cupos sugeridos | Capacidad final indicada en `slots`, para cupos de la misma jornada | No cambia la agenda |
| DAY_SLOTS, CAPACITY_ALERT | Deja constancia; no cambia la agenda | No admitida (400) | Deja constancia |
| REQUEST_SLOT, RESCHEDULE | 409: se deciden con O-07 | | |

- **Motivo:** obligatorio para MODIFIED y REJECTED (1 a 500 caracteres); opcional al aceptar.
- **Validaciones del sobrecupo:**
  - Bloquea con `FOR UPDATE` todos los cupos publicados de la jornada.
  - Exige que la capacidad de la jornada siga siendo la que vio el modelo; si no, responde 409 y no cambia nada.
  - Cada cupo debe estar publicado, ser futuro y quedar con más capacidad que la actual, sin pasar de 20.
  - El total agregado no puede superar ⌊C × 1,10⌋ − C (RN-35); si lo supera, responde 400.
  - Solo cambia `capacidad`: la duración del cupo queda igual (PA-22).
- **Lo aplicado** se guarda en `decision_sugerencia.valor_aplicado`, con la capacidad, el sobrecupo y cada cupo con su capacidad anterior y la aplicada. La API lo muestra en `decision.appliedValue`, con la clave nueva `appliedCapacity`.
- **Una sola decisión por sugerencia:** la segunda responde 409. El sobrecupo decidido congela la jornada para la generación nocturna (O-04).
- **Auditoría:** `SUGERENCIA_AGENDA_DECIDIDA` con tipo, decisión, fecha, versión del modelo, sobrecupo aplicado y cupos modificados. El motivo no va en el detalle, porque la auditoría no admite texto libre; queda en `decision_sugerencia`.
- **Avisos:** ninguna decisión de los tipos actuales cambia citas, así que no corresponde ningún aviso. Los avisos de cita (por ejemplo CITA_REPROGRAMADA) llegarán con O-07 por el trigger de N-01.

## 2. Vencimiento (PA-21)

- Decidir una sugerencia con `vence_en` ya pasado responde 409 «La sugerencia venció sin decisión; la agenda no cambió.»
- `salud_u.vencer_sugerencias_agenda()` inserta `VENCIDA` (sin persona) en todas las sugerencias no decididas que vencieron. Es idempotente.
- La tarea nocturna la ejecuta después de las estimaciones y antes de regenerar las sugerencias, cada paso en su propio try/catch.

## 3. Listado

`GET /api/scheduling/suggestions` ahora incluye `decision`: null si la sugerencia está pendiente, o `{decidedAt, decidedBy, decidedByName, reason, appliedValue}`. En EXPIRED, `decidedBy` es null. Para agregar esas columnas, `listar_sugerencias_agenda` se recreó con DROP y CREATE.

## 4. Evidencia

- Pruebas:
  - `DecisionSugerenciaIntegrationTest` (5):
    - PA-22 de punta a punta: el cupo sube de 1 a 2, la duración no cambia, se audita sin el motivo, una segunda decisión da 409 y la regeneración no suma otro sobrecupo.
    - Validaciones de MODIFIED: falta el motivo, supera el 10 %, la capacidad no sube, el cupo es de otra jornada, campos extra, y la jornada cambió (409); nada se aplica a medias.
    - Rechazo y tipos que solo dejan constancia sin tocar la agenda.
    - PA-21: vencimiento, idempotencia y estado EXPIRED.
    - Permisos y CSRF; el rol de ejecución no decide sin actor.
  - `DayCloseSchedulingTest` actualizado con el orden cierre → estimación → vencimiento → generación.
- `mvn verify`: 285 pruebas, 0 fallas; cobertura de funciones SQL 135/137.
- Ensayo sobre una copia de la base local (V90 → V91): la migración aplica; una decisión de prueba (revertida) deja ACCEPTED, el nombre de quien decidió y el evento de auditoría.
- Local: Flyway en V91, readiness 200, 0 funciones abiertas a PUBLIC y 0 ERROR/WARN en el log. Respaldo previo: `backups/salud-u-20261027T062458Z.dump`.

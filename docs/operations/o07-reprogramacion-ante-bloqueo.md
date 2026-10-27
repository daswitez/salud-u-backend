# O-07 · Reprogramar citas ante un bloqueo

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V92__reprogramacion_ante_bloqueo.sql`.
Trazabilidad: UC-31, RF-40, RN-33, PV-7.6.

## 1. Flujo (solo Administración)

1. **Proponer:** `POST /api/scheduling/block-proposals` con `{staffId, date, startTime?, endTime?, label}`. Sin horas es el día completo. Llama a `proponer_bloqueo_jornada`.
   - **Sin citas en el horario:** registra el bloqueo en el acto, con estado `APPLIED`.
   - **Con citas programadas:** crea la propuesta `PENDING` y una sugerencia `REPROGRAMACION` (API `RESCHEDULE`) por cita.
   - **Cupo sugerido:** el compatible libre **más cercano en el tiempo**, antes o después. Compatible quiere decir:
     - de la misma especialidad, o del área;
     - publicado y futuro;
     - con lugar según `cantidad_reservada` y según las citas no canceladas;
     - fuera del horario que se bloquea;
     - sin choque con otra cita del paciente.

     Las citas se recorren por hora y un mismo lugar no se sugiere dos veces dentro de la propuesta. Si no hay cupo, `slotId` va null y la explicación lo dice.
   - **Rechazos:** 409 si hay una propuesta pendiente que se superpone, o si el horario tiene una cita ya iniciada o con el paciente presente (LLEGADA).
2. **Decidir cada reprogramación:** con el endpoint de O-06, `POST /api/scheduling/suggestions/{id}/decision`.
   - `ACCEPTED`: mueve la cita al cupo sugerido; 400 si no había cupo.
   - `MODIFIED`: requiere motivo y `slots: [{slotId}]` con un solo cupo de destino.
   - `REJECTED`: requiere motivo y deja la cita donde está.
3. **Aplicar el bloqueo:**
   - Después de cada decisión, si en el horario ya no quedan citas programadas ni en curso, se registra el `bloqueo_disponibilidad` y los cupos libres del médico en ese horario pasan a `BLOQUEADO`.
   - Si una reprogramación se rechazó y la cita se canceló después por el flujo normal, `POST /api/scheduling/block-proposals/{id}/apply` registra el bloqueo. Responde 409 si todavía hay citas e 200 si ya estaba aplicado.
   - `GET /api/scheduling/block-proposals/{id}` muestra el estado, las citas pendientes y las reprogramaciones.

El bloqueo del propio médico (`crear_mi_bloqueo_disponibilidad`, V7) **no cambió**: sigue rechazando horarios con citas.

## 2. `reprogramar_cita(p_id_cita, p_id_cupo, p_motivo)`

- Exige el rol ADMINISTRATIVO y un motivo de 1 a 500 caracteres. Al aceptar sin motivo se usa «Bloqueo de agenda: <etiqueta>».
- Bloquea la cita y luego ambos cupos, en orden de id para evitar interbloqueos.
- **Rechaza (409/400):**
  - una cita que no esté PROGRAMADA a futuro o que ya tenga una atención;
  - un cupo de otra especialidad;
  - un cupo no publicado, pasado o lleno;
  - un cupo que choque con otra cita activa del paciente (la cita ocupa una hora, como en la asignación).
- **Efecto:**
  - Cambia `id_cupo`, `programada_para` e `id_personal_asignado`.
  - Resta 1 a `cantidad_reservada` del cupo anterior (sin bajar de 0) y suma 1 al nuevo.
  - Si la cita viene de una derivación ASIGNADA, la derivación pasa al nuevo especialista, porque de él depende el acceso al contexto remitido.
- **Registro:** un evento en `evento_estado_cita` (PROGRAMADA→PROGRAMADA con el motivo) y la auditoría `CITA_REPROGRAMADA`, con los cupos y médicos anterior y nuevo y sin el motivo.
- **Aviso:** el cambio de cupo dispara `CITA_REPROGRAMADA` por el trigger de N-01: «Tu cita fue reprogramada para el DD/MM/AAAA HH:MM». Si el paciente no tiene cuenta no hay bandeja y no se genera aviso; esto ya era así antes de O-07.

## 3. Base de datos

- `propuesta_bloqueo`:
  - columnas: personal, fecha, horas locales, instantes `bloquea_desde`/`bloquea_hasta`, etiqueta, estado PENDIENTE/APLICADA, id_bloqueo, creado_por, aplicada_por y aplicada_en;
  - RLS forzada y sin acceso directo al rol de ejecución.
- Dominio nuevo `estado_propuesta_bloqueo`: PENDING, APPLIED. El diccionario queda en 117 equivalencias y 34 dominios.
- `sugerencia_agenda` gana `id_cita` e `id_propuesta_bloqueo`, que son obligatorias solo en REPROGRAMACION. Hay un índice único por (propuesta, cita).
- `valor_sugerido_api` traduce las claves nuevas: blockProposalId, appointmentId, patientId, patientName, originalSlotId, originalStartsAt, staffId, staffName y shiftMinutes.
- `decidir_sugerencia_agenda` se recreó con la rama REPROGRAMACION. CUPO_SOLICITUD sigue sin decidirse (409), porque O-05 no guarda sus sugerencias.

## 4. Evidencia

- `ReprogramacionBloqueoIntegrationTest` (4):
  - **PV-7.6:** tres citas reciben tres cupos distintos ordenados por cercanía; proponer no mueve nada (RN-33). Al aceptar, se mueve la cita, se actualizan los contadores, la derivación pasa al nuevo especialista, se genera el aviso con la nueva hora y se registran el motivo y la auditoría. Al modificar se usa otro cupo. Con la tercera decisión se registra el bloqueo y los cupos quedan BLOQUEADO.
  - **Rechazo:** la propuesta sigue pendiente, `apply` responde 409, luego se cancela la cita y `apply` aplica el bloqueo; aplicar otra vez no lo duplica.
  - **Casos límite:** sin citas el bloqueo es inmediato; sin cupo, aceptar da 400 y modificar funciona; también se prueban otra especialidad, `capacity` en una reprogramación y el cupo nuevo.
  - **Validaciones:** roles, cuerpo, médico inexistente, cita con el paciente presente, propuesta superpuesta, cupo lleno, choque con otra cita del paciente, bloqueo del médico intacto y el rol de ejecución sin acceso.
- `mvn verify`: 289 pruebas, 0 fallas; cobertura de funciones SQL 141/143.
- Ensayo sobre una copia de la base local (V91 → V92): una jornada real con 8 citas genera 8 reprogramaciones con cupo; al aceptarlas, la propuesta pasa a APPLIED con 0 pendientes. Se hizo dentro de una transacción revertida.
- Local: Flyway en V92, readiness 200, 0 funciones abiertas a PUBLIC, RLS forzada en `propuesta_bloqueo` y 0 ERROR/WARN en el log. Respaldo previo: `backups/salud-u-20261027T063955Z.dump`.

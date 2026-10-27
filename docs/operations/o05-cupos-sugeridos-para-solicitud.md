# O-05 · Cupos sugeridos para una solicitud

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V90__cupos_sugeridos_para_solicitud.sql`.
Trazabilidad: UC-07 extendido (flujo alternativo C), RF-40, PV-7.5 del backlog.

## 1. Qué cupos se consideran

`salud_u.cupos_para_solicitud(id)` usa las mismas condiciones que `asignar_solicitud_cita`, así que nunca sugiere un cupo que la asignación rechazaría:

- La solicitud debe estar PENDIENTE; si es una derivación, esta debe estar PENDIENTE_ASIGNACION y ser del mismo paciente.
- El cupo debe estar PUBLICADO y no haber empezado.
- Debe tener lugar según `cantidad_reservada` **y también** según las citas no canceladas, porque en la base local esos dos valores no siempre coinciden.
- Especialidad: la de la derivación o la de la solicitud. Una solicitud INICIAL solo ve cupos del área.
- El cupo no debe chocar con otra cita activa del paciente. Como en la asignación, esa cita ocupa una hora.

La función solo lee y exige el rol ADMINISTRATIVO. Devuelve una fila con el tipo, la prioridad y los cupos en jsonb. Cada cupo trae la capacidad y las citas de su jornada, y la asistencia estimada de O-03 (`estimacion_vigente`).

## 2. Orden (`SugeridorCupoSolicitud`, Java puro, versión `o05-v1`)

Puntaje = 100·(1 − (w·espera + (1 − w)·ocupación)).

| Término | Definición |
|---|---|
| espera | días hasta el cupo (hora de Bolivia) / 30, con tope 1 |
| ocupación | (citas de la jornada + 1) × asistencia estimada / capacidad de la jornada, con tope 1 |
| w | 0,9 si la derivación es URGENTE, 0,7 si es PRIORITARIA, 0,5 si es de RUTINA o si no hay derivación |

La prioridad es la misma para todos los cupos de una solicitud, así que no suma puntos: decide cuánto pesa la espera frente a la ocupación. Preferir la jornada menos cargada reparte el trabajo y llena antes las jornadas que quedarían ociosas. Los empates se resuelven por el cupo más temprano. Se devuelven los tres mejores, cada uno con su explicación en español: fecha, médico, espera, ocupación con la cita, asistencia y su fuente, pesos y puntaje.

Ejemplo (prueba de integración):
- Cupo A: mañana, en una jornada con 3 de 4 lugares tomados.
- Cupo B: en 10 días, en una jornada vacía.
- Ambas jornadas tienen 80 % de asistencia.

| Prioridad | Cupo A | Cupo B | Primero |
|---|---|---|---|
| Urgente | 89 | 68 | A |
| Rutina | 58,3 | 73,3 | B |

## 3. API

- `GET /api/appointment-requests/{id}/suggested-slots`, solo ADMINISTRATIVE, con `Cache-Control: no-store, private`.
- Responde `{requestId, appointmentType, priority, modelVersion, waitWeight, occupancyWeight, slots[≤3]}`, con los cupos ordenados por `rank`.
- Errores:
  - 404: la solicitud no existe.
  - 409: la solicitud no está pendiente, o la derivación ya no es programable.
  - 401/403: sin sesión o con otro rol.
- **No cambia nada:** la asignación sigue siendo `POST /api/appointment-requests/{id}/assign`, sin cambios. La consulta no se guarda en `sugerencia_agenda`; el tipo CUPO_SOLICITUD queda reservado.
- La ruta está en el OpenAPI (`SuggestedSlots`) y en el proxy de `next.config.ts`. Ya estaba cubierta por `/api/appointment-requests/**` en `SecurityConfig`.

## 4. Evidencia

- Pruebas:
  - `SugeridorCupoSolicitudTest` (4): el orden se invierte entre urgente y rutina con los puntajes exactos, los pesos, la elección de los tres mejores con desempate, los topes y el texto de la explicación.
  - `CuposSugeridosIntegrationTest` (3):
    - exclusiones: otra especialidad, área, cupo ya empezado, choque con otra cita del paciente y cupo lleno;
    - la consulta no cambia la agenda, y el mejor cupo se asigna con el endpoint de siempre;
    - una solicitud INICIAL solo ve el área, y una lista vacía es válida;
    - errores 401/403/404/409, y el rol de ejecución no puede consultar sin actor administrativo.
- `mvn verify`: 280 pruebas, 0 fallas; cobertura de funciones SQL 133/135.
- Ensayo sobre una copia de la base local (V89 → V90): la derivación URGENT pendiente recibe 3 cupos, y de las dos solicitudes de especialidad pendientes, una recibe 1 cupo y la otra una lista vacía.
- Local: Flyway en V90, readiness 200, 0 funciones abiertas a PUBLIC y 0 ERROR/WARN en el log. Respaldo previo: `backups/salud-u-20261027T061306Z.dump`.

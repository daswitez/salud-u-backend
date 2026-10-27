# O-04 · Sugerencias de cupos, sobrecupo y alertas de capacidad

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V89__sugerencias_agenda_y_alertas_capacidad.sql`.
Trazabilidad: RF-38, RN-35, PV-7.4.

## 1. Modelo (`SugeridorAgenda`, Java puro, versión `o04-v1`)

| Sugerencia | Regla |
|---|---|
| CUPOS_JORNADA (API `DAY_SLOTS`) | Una por jornada futura (fecha, médico, especialidad). Con C lugares publicados y asistencia Beta(α, β), sugiere el mayor N en [C, ⌊C × 1,10⌋] con P(lleguen más de C) ≤ 20 %, calculado con la beta-binomial. |
| SOBRECUPO (API `OVERBOOKING`) | Solo si N > C. Dice qué cupos subir: +1 por cupo empezando por los últimos de la jornada, sin pasar de 20 por cupo. Se aplica **subiendo `capacidad`**; sugerir no toca el cupo (eso lo hace la decisión, O-06). |
| ALERTA_CAPACIDAD (API `CAPACITY_ALERT`) | Por especialidad (NULL = área), para 10 días hábiles (lunes a viernes) desde la fecha. Demanda proyectada = solicitudes pendientes + Σ demanda estimada de cada día. Alerta si supera el 100 % o queda bajo el 50 % de los **lugares libres** publicados, o si hay demanda y ningún lugar libre. |

- α y β son los del nivel que da la asistencia vigente (médico, especialidad o área, O-03). Por eso V89 agrega `alfa_vigente` y `beta_vigente` a `estimacion_agenda` (se vacía y se recalcula esa misma noche). Si no hay estimación, se usan el valor inicial de la especialidad, el del área o el de DV-10 (8/2).
- La demanda de un día es la suavizada de la especialidad para ese día de la semana y tipo de período; si no hay, el valor inicial; si tampoco, la capacidad publicada ese día (DV-10), y ese día se cuenta en `dias_sin_estimacion`.
- **Lugares libres** = capacidad − citas no canceladas, solo en cupos futuros. No se usa `cantidad_reservada`, que en la base local no coincide con las citas en 64 cupos.
- Con la regla del 10 %, el sobrecupo solo es posible desde 10 lugares por jornada (⌊9 × 1,1⌋ = 9). En los datos locales ninguna jornada llega a 10, así que hoy no aparecen sobrecupos.
- Cada sugerencia lleva una explicación en español con los datos y la regla (RNF-13).

## 2. Base de datos (V89)

- `sugerencia_agenda`: tipo (5 valores; CUPO_SOLICITUD y REPROGRAMACION quedan para O-05 y O-07), fecha, id_personal, id_especialidad, `valor_sugerido` jsonb (objeto, claves en español), explicacion, version_modelo, vence_en. Hay un índice único por (tipo, fecha, médico, especialidad) para los tres tipos generados. Las de jornada vencen al empezar la jornada; las alertas, al empezar el día siguiente.
- `decision_sugerencia`: una por sugerencia, con decision ACEPTADA/MODIFICADA/RECHAZADA/VENCIDA, motivo, valor_aplicado y decidida_por (NULL solo en VENCIDA). Su escritura es de O-06.
- Ambas tienen RLS forzada y no dan acceso directo al rol de ejecución.
- Diccionario:
  - `tipo_sugerencia`: DAY_SLOTS, OVERBOOKING, CAPACITY_ALERT, REQUEST_SLOT, RESCHEDULE.
  - `estado_sugerencia`: PENDING, ACCEPTED, MODIFIED, REJECTED, EXPIRED.
  - Total: 115 equivalencias en 33 dominios.
- Funciones:
  - `jornadas_para_sugerencias(desde, hasta)` y `demanda_para_alertas(desde, hasta)`: datos para el generador. Solo leen agenda, calendario y estimaciones (RN-34; hay una prueba que lo controla).
  - `guardar_sugerencias_agenda(lote, versión, desde, hasta)`: usa un bloqueo consultivo. Rechaza otros tipos, fechas fuera de la ventana, claves desconocidas y duplicados. Borra las pendientes que ya no aplican, actualiza solo lo que cambió y nunca toca las decididas. Cuando el SOBRECUPO de una jornada ya tiene decisión, esa jornada queda congelada para no sumar un sobrecupo sobre otro.
  - `listar_sugerencias_agenda(fecha)`: solo Administración. Devuelve códigos y claves en inglés (`valor_sugerido_api`) y el estado calculado: la decisión; si no hay, EXPIRED una vez pasado `vence_en`, y si no, PENDING.

## 3. Ejecución y API

- La tarea nocturna (`DayCloseJob`, detrás de `salud-u.scheduling.enabled`) cierra las jornadas, recalcula las estimaciones y regenera las sugerencias de hoy más 10 días hábiles. Cada paso está en su propio try/catch.
- `GET /api/scheduling/suggestions?date=AAAA-MM-DD`: la fecha es opcional y por defecto es hoy en Bolivia. Solo ADMINISTRATIVE. Responde con `Cache-Control: no-store, private` y devuelve las alertas primero. Una fecha mal formada da 400 con «La fecha debe tener el formato AAAA-MM-DD.»
- La ruta está en `SecurityConfig`, en el OpenAPI (`ScheduleSuggestion`) y en el proxy de `next.config.ts`.

## 4. Evidencia

- Pruebas:
  - `SugeridorAgendaTest` (5): cola beta-binomial (uniforme 1/(N+1), valor exacto y aproximación binomial), límite del 10 % y riesgo, reparto en los últimos cupos con tope de 20, umbrales 100/50 % y ventana de días hábiles.
  - `SugerenciasAgendaIntegrationTest` (5): PV-7.4 de punta a punta con regeneración idempotente, sobrecupo decidido congelado, estado EXPIRED, alertas por falta y por exceso de oferta, permisos 401/403/400, rechazo de lotes inválidos y lecturas solo de agenda.
- `mvn verify`: 273 pruebas, 0 fallas; cobertura de funciones SQL 132/134.
- Ensayo sobre una copia de la base local (V88 → V89): cierre de 89 filas, 89 estimaciones y 47 sugerencias (19 de jornada y 28 alertas); al repetir, 0 cambios.
- Local: Flyway en V89, readiness 200, 0 funciones abiertas a PUBLIC, RLS forzada en ambas tablas y 0 ERROR/WARN en el log. Respaldo previo: `backups/salud-u-20261027T055840Z.dump`.

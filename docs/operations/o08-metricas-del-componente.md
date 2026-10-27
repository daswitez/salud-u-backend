# O-08 · Métricas del componente

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V93__metricas_componente_agenda.sql`.
Trazabilidad: RF-41, cuadro 3.70 (indicadores de evaluación del componente de optimización).

## 1. Endpoint

`GET /api/scheduling/metrics?from=AAAA-MM-DD&to=AAAA-MM-DD`

- Solo ADMINISTRATIVE.
- Respuesta con `Cache-Control: no-store, private`.
- **Período:** en fechas de Bolivia, de hasta 366 días. Por defecto, los 30 días que terminan ayer.
- **Sin datos:** un indicador sin datos sale `null`, no 0.

## 2. Indicadores (cuadro 3.70)

| Campo | Definición | Fuente |
|---|---|---|
| `idlePlaces` | Lugares publicados sin paciente atendido sobre lugares publicados, en jornadas cerradas de cada médico. | `observacion_jornada` (O-02) |
| `waitTime` | Días entre `solicitado_en` y la hora de la cita, para solicitudes asignadas en el período: promedio, mediana y p90. | `solicitud_cita`, `cita` |
| `overload` | Jornadas en que llegaron más pacientes que la capacidad **definida por el médico**, es decir, la observada menos el sobrecupo que Administración aplicó (O-06). Se muestra junto al riesgo máximo configurado (0,20) y las jornadas con sobrecupo. | `observacion_jornada`, `decision_sugerencia` |
| `attendanceCalibration` | Puntuación de Brier por cita: promedio de (p − resultado)². Línea base: asistencia constante igual al valor inicial. `skill = 1 − brier / línea base`; positivo significa que el modelo calibra mejor. | `EvaluadorAgenda` |
| `demandError` | Error absoluto medio de la demanda diaria proyectada por especialidad. Línea base: repetir las solicitudes del mismo día de la semana anterior, comparado solo en los días que la tienen. | `EvaluadorAgenda` |
| `suggestions` | Sugerencias del período por estado: aceptadas, modificadas, rechazadas, vencidas y pendientes, también por tipo. `acceptanceRate = (aceptadas + modificadas) / emitidas`. | `sugerencia_agenda`, `decision_sugerencia` |
| `notifications` | Avisos de bandeja registrados, entregados y leídos, por tipo de evento. `readRate = leídos / entregados`. | `notificacion` |

### Cómo se evalúan los pronósticos sin hacer trampa

`EvaluadorAgenda` recorre los días del período en orden. Para cada día vuelve a correr `EstimadorAgenda` solo con las jornadas **anteriores**, igual que la tarea nocturna. Con eso pronostica la asistencia de cada cita (médico → especialidad → área → valor inicial, como `estimacion_vigente`) y la demanda de cada especialidad (suavizada → valor inicial → capacidad, como `demanda_para_alertas`). Así cada pronóstico se compara con un resultado que todavía no conocía.

No se usan las filas de `estimacion_agenda`, porque esa tabla guarda solo la última estimación.

## 3. Decisiones

- **Reparto del cálculo:** los conteos están en SQL (`metricas_agenda`, que exige ADMINISTRATIVO y solo lee). La calibración está en Java, porque reconstruye el modelo día por día.
- **Línea base de asistencia:** es la del cuadro 3.70, una asistencia constante igual al valor inicial.
- **CUPO_SOLICITUD (O-05):** no se guarda, así que no aparece en la aceptación de sugerencias.
- **Avisos fallidos:** el cuadro 3.70 habla de "avisos fallidos reintentados". La bandeja no tiene fallas de envío, porque se descartó el correo, así que se informan registrados, entregados y leídos.

## 4. Evidencia

- `EvaluadorAgendaTest` (4):
  - sin historia, Brier = línea base;
  - cada día se pronostica solo con los anteriores y el modelo aprende de las ausencias;
  - el error de demanda y la línea base de la semana anterior, aunque esa semana esté fuera del período;
  - sin datos, todo es null.
- `MetricasAgendaIntegrationTest` (2):
  - todos los indicadores con valores calculados a mano (4+1 ociosos de 22, esperas de 4 y 2 días con p90 3,8, sobrecarga medida sin el sobrecupo, Brier 0,13, error 5, 5 sugerencias por estado y tipo, avisos);
  - el período por defecto;
  - el período vacío con null;
  - fechas inválidas o más de 366 días → 400; otros roles → 403; sin sesión → 401; sin actor administrativo, la función falla.
- `mvn verify`: 295 pruebas, 0 fallas; cobertura de funciones SQL 142/144.
- **Ensayo sobre una copia local (V92 → V93):** la función responde.
  - La base local no tiene jornadas cerradas, así que ociosos, sobrecarga, Brier y error salen sin datos.
  - La espera promedio sale de 331 días porque las citas de prueba están agendadas hasta 2029. No es un error del cálculo.
- **Local:** Flyway en V93, readiness 200, 0 funciones abiertas a PUBLIC, 0 ERROR/WARN en el log. Respaldo previo: `backups/salud-u-20261027T070004Z.dump`.

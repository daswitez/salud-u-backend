# O-03 · Estimaciones de asistencia y demanda

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V88__estimaciones_agenda_y_recordatorio_reforzado.sql`.
Trazabilidad: RF-38, RN-36, PV-7.3.

## 1. Modelo (`EstimadorAgenda`, Java puro)

`scheduling/application/EstimadorAgenda.java` no depende de Spring ni de la base. Recibe las observaciones de O-02 y los valores iniciales de O-01, y devuelve una estimación por **especialidad** (NULL = área), **médico** (NULL = fila de la especialidad), **día ISO de la semana** (1 = lunes) y **tipo de período** (NULL = fecha sin período en el calendario).

Para cada clave recorre las jornadas en orden de fecha:

| Paso | Fórmula | Parámetro |
|---|---|---|
| Asistencia | `α ← λ·α + asistencias`, `β ← λ·β + ausencias` | λ = 0,95 por jornada |
| Demanda (solo filas de especialidad) | `D ← θ·d + (1 − θ)·D`, con d las solicitudes ingresadas | θ = 0,3 |
| Punto de partida (DV-10) | `α₀ = peso·asistencia`, `β₀ = peso·(1 − asistencia)`, `D₀` = demanda esperada o, si no se indicó, la capacidad de la primera jornada observada | peso 10, asistencia 0,8 |

- Los valores iniciales son los de la especialidad y el tipo de período; si no hay, los del área; si tampoco, los de DV-10.
- **Asistencia vigente:** la propia si reúne 20 citas observadas (asistencias + ausencias, sin olvido); si no, la de la especialidad y luego la del área, cada una con el mismo umbral. Si ningún nivel llega a 20, se usa la propia, que todavía pesa sobre todo el valor inicial. La fuente queda registrada: MEDICO, ESPECIALIDAD, AREA o INICIAL (API: DOCTOR, SPECIALTY, AREA, INITIAL_VALUE).
- **Versión del modelo:** `o03-v1`, guardada en cada fila junto con `calculada_en`. Cambiar λ, θ, el umbral o los valores por defecto obliga a subir la versión.

**Se recalcula entero en cada ejecución.** Un día se vuelve a cerrar durante una semana (O-02), así que sumar cada cierre como evidencia nueva contaría dos veces la misma jornada. Recalcular desde las observaciones da siempre el mismo resultado para los mismos datos, y con este volumen es barato (RNF-14).

## 2. Tabla `estimacion_agenda`

Columnas: `alfa_asistencia`, `beta_asistencia`, `demanda_suavizada` (NULL en las filas de médico), `citas_observadas`, `jornadas_observadas`, `ultima_fecha`, `asistencia_vigente`, `fuente_vigente`, `version_modelo` y `calculada_en`.

Restricciones:

- una fila por clave, con `UNIQUE NULLS NOT DISTINCT`;
- α y β positivos;
- la fuente MEDICO solo en filas de médico;
- RLS forzada solo con la política del migrador, sin permisos para el rol de la aplicación.

## 3. Funciones

| Función | Rol | Uso |
|---|---|---|
| `observaciones_para_estimacion()` | aplicación | Todas las observaciones, con el tipo de período en código de API. |
| `valores_iniciales_para_estimacion()` | aplicación | Valores iniciales, sin actor (los usa la tarea nocturna). |
| `guardar_estimaciones_agenda(jsonb, versión)` | aplicación | Reemplaza todas las estimaciones en una transacción, con bloqueo consultivo. Un lote inválido (clave repetida, código desconocido, α en 0, demanda en una fila de especialidad sin valor…) responde `ESTIMACIONES_INVALIDAS` y conserva las anteriores. |
| `asistencia_estimada(médico, especialidad, fecha)` | privada | Asistencia vigente de la fila del médico; si no existe, la de su especialidad y luego la del área, con el día de la semana y el tipo de período de la fecha. NULL si no hay estimaciones. |

Igual que el cierre, todas solo leen agenda y calendario. Una prueba revisa las tablas que nombra cada una.

`ScheduleEstimationService` lee con las dos primeras, llama a `EstimadorAgenda` y guarda, todo en una transacción `REPEATABLE READ`. `DayCloseJob` (O-02) lo ejecuta después del cierre. Si el cierre falla, igual estima con las observaciones que ya había; si la estimación falla, se conservan las anteriores.

## 4. Recordatorio reforzado (RN-36, DV-09)

`generar_recordatorios_citas_en`, la misma tarea de N-03 cada 15 minutos, agrega un segundo aviso `RECORDATORIO_REFORZADO` (API `APPOINTMENT_REMINDER_REINFORCED`) cuando se cumplen todas estas condiciones:

- es el día de la cita, desde las 07:00 de Bolivia, y la cita sigue `PROGRAMADA` más tarde ese día;
- la asistencia estimada de su médico, especialidad, día y período es **menor al 70 %**;
- el destinatario no apagó `recibir_recordatorios` ni `recordatorio_reforzado`; ambos están activos por defecto.

Sin estimaciones no hay reforzado. El mensaje es "Tu cita es hoy a las HH:MM (hora de Bolivia). Si no puedes asistir, cancélala para liberar el cupo.", sin datos clínicos. Repetir la generación no lo duplica, y la bandeja le aplica la misma vigencia que V85 da al recordatorio ordinario. El recordatorio del día anterior no cambia.

## Pruebas y resultados

- `mvn verify`: **263 pruebas**, sin fallos, errores ni omisiones; `plpgsql_check` aprobado; inventario de inglés en cero. Las pruebas ejecutan 124 de las 126 funciones SQL, incluidas las cuatro nuevas.
- `EstimadorAgendaTest` (8 pruebas unitarias):
  - PV-7.3: con 8 asistencias y 2 ausencias, α = 15,6 y β = 3,9;
  - olvido por jornada en orden de fecha, sin importar el orden de entrada;
  - demanda desde el valor inicial o desde la capacidad;
  - valores iniciales de la especialidad, del área o de DV-10;
  - claves separadas por día y período;
  - fuentes MEDICO, ESPECIALIDAD, AREA e INICIAL según el umbral de 20.
- `EstimacionAgendaIntegrationTest` (6 pruebas): recálculo completo guardado en español y versionado, que da lo mismo al repetir; paso a la estimación propia al llegar a 20 citas; permisos y siete lotes inválidos que no tocan lo guardado; la búsqueda médico → especialidad → área; el reforzado (hora de inicio, umbral, preferencias, sin duplicados) y su vigencia en la bandeja; las tablas que lee cada función.
- `DayCloseSchedulingTest`: la tarea estima después de cerrar, y un fallo en cualquiera de los dos pasos no impide el otro ni el siguiente intento.

## Ensayo y base local

1. Ensayo sobre una copia de la base local en V87:
   - sin estimaciones, los recordatorios generados antes y después de V88 son idénticos (10 avisos en tres instantes de enero de 2029);
   - con una estimación de 0,60 para los médicos del 05/01/2029, a las 08:00 aparecen los 5 reforzados; se deshizo.
2. Respaldo previo: `backups/salud-u-20261027T053912Z.dump`.
3. Backend reconstruido. Flyway aplicó **V88**, la preparación responde 200 y no hay errores ni advertencias en el log. El diccionario queda en 105 equivalencias / 31 dominios.
4. Comprobado sobre la base local: 0 funciones abiertas a PUBLIC y RLS forzada en `estimacion_agenda`. El rol de la aplicación pudo cerrar los días, leer las 89 observaciones y guardar, dentro de una transacción que se deshizo. El programador local sigue apagado.

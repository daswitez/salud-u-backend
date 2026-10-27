# O-09 · Simulador para la evaluación

Fecha: 27 de octubre de 2026. Estado: **terminada**. Sin migración ni cambios en el código de producción.
Trazabilidad: sección 3.5 (primera etapa de la evaluación del componente), cuadro 3.70, Apéndice A.6.

## 1. Dónde vive y cómo se corre

- **Ubicación:** `src/test/java/.../scheduling/simulacion/` (`SimuladorAgenda`, `InformeSimulacion`) y los escenarios en `src/test/resources/simulacion/escenarios.csv`.
- **Sin perfil:** no hace falta el perfil `simulacion`, porque el código de prueba no se empaqueta. Comprobado: el jar no tiene ninguna clase ni recurso de la simulación.
- **Corrida:** cada `mvn verify` la corre con los valores por defecto y escribe en `target/simulacion/`. Para una corrida propia:

```
mvn -o test -Dtest=InformeSimulacionTest -Dsimulacion.escenarios=mis-escenarios.csv \
    -Dsimulacion.replicas=50 -Dsimulacion.semilla=1 -Dsimulacion.aceptacion=0.8 -Dsimulacion.salida=docs/evaluacion
```

## 2. Modelo de la simulación

- **Escenarios:** cada fila de `escenarios.csv` es un tramo de semanas de una especialidad con un tipo de período. Lleva:
  - médicos, capacidad por jornada y semanas;
  - los **valores iniciales** del modelo: demanda diaria, asistencia esperada y peso;
  - la **asistencia real** con que se sortea quién llega;
  - la temporada (ALTA, NORMAL o BAJA).

  El orden de las filas es el calendario. Antes del primer tramo van 2 semanas de calentamiento y después del último, un enfriamiento del largo del horizonte; ninguno de los dos se mide.
- **Llegadas:** cada día hábil llegan Poisson(demanda) solicitudes. Cada solicitud recibe un número U(0,1) y el paciente llega si ese número es menor que la asistencia real.
- **Mismo azar en las dos políticas:** ambas reciben las mismas llegadas y los mismos números (números aleatorios comunes), así que la diferencia solo viene de la agenda.
- **AGENDA_FIJA:** cada médico publica todos los días hábiles su capacidad, con 10 días hábiles de horizonte. Las solicitudes se asignan en orden de llegada al primer lugar libre.
- **CON_SUGERENCIAS:** las mismas clases que producción.
  - Cada noche, `EstimadorAgenda` (o03-v1) corre con las jornadas cerradas.
  - Cada jornada que entra al horizonte recibe el sobrecupo de `SugeridorAgenda.jornada` (o04-v1, RN-35).
  - Los lunes Administración revisa `SugeridorAgenda.alerta`:
    - con exceso, agrega jornadas adicionales de un médico, hasta 2 por semana y solo hasta cubrir la demanda proyectada;
    - con defecto, libera jornadas sin citas mientras los lugares libres sigan cubriendo la demanda proyectada.
  - Cada sugerencia se acepta con probabilidad `aceptacion` (1 por defecto). Con 0, la política reproduce exactamente la agenda fija; hay una prueba de esto.
- **Métricas:** las de O-08 con las mismas definiciones. Brier y error de demanda salen de `EvaluadorAgenda`, que pronostica cada día solo con los anteriores. Los avisos no se simulan.

## 3. Archivos para el Apéndice A.6

Cada fila empieza con `origen=SIMULACION`, la fecha de ejecución, las versiones (simulador o09-v1, estimador o03-v1 y sugeridor o04-v1), la semilla, las réplicas y los parámetros.

- `simulacion-o09-detalle-<fecha>.csv`: una fila por réplica, especialidad, tramo y política.
- `simulacion-o09-resumen-<fecha>.csv`: el promedio de las réplicas y, para la política con sugerencias, la diferencia pareada contra la agenda fija en ociosos y espera, con su IC95 (t de Student).
  - **Criterio** según la temporada: en BAJA, menos ociosos; en ALTA, menos espera; en todas, sobrecarga ≤ 0,20.
  - **Veredicto:** `SI` si todo el intervalo favorece al componente, `NO` si lo contradice y `NO_CONCLUYENTE` si incluye el cero.

La corrida de referencia está en `docs/evaluacion/`. Usa **valores de ejemplo** que hay que reemplazar por los que informe el personal; siempre se presenta como simulación.

## 4. Hallazgos de la corrida de referencia (valores de ejemplo, 20 réplicas)

- **Temporada alta:** la espera baja de forma significativa (Odontología −3,4 días; Psicología en exámenes −2,2 días), a costa de algunos cupos ociosos más por las jornadas adicionales.
- **Temporada baja:** los ociosos bajan (Odontología −22 puntos; Psicología −8), pero **la espera sube** (+2,6 y +1,4 días), porque se liberan jornadas.
- **Sobrecarga:** entre 0 % y 2,2 % de las jornadas en todos los tramos, muy por debajo del 20 %.
- **Sobrecupo sin demanda:** el sobrecupo se sugiere solo por el riesgo de asistencia, sin mirar la demanda. En temporada normal sube los ociosos (Odontología en clases +11 puntos), aunque acorta la espera.
- **Calibración:** cuando la asistencia informada difiere poco de la real (0,80 contra 0,75), el Brier del modelo queda prácticamente igual al de la línea base, y a veces apenas peor. El ruido de estimar por médico, día de la semana y tipo de período pesa más que el sesgo que corrige. Cuando difiere mucho (0,9 contra 0,6), el modelo es claramente mejor; hay una prueba de esto.
- **Demanda:** el error absoluto medio del modelo es menor que repetir la semana anterior en todos los tramos.
- **RN-35:** con menos de 10 lugares por jornada, ⌊C × 1,10⌋ = C y no hay sobrecupo posible.

## 5. Evidencia

- `SimuladorAgendaTest` (6):
  - la misma semilla da la misma corrida y las dos políticas reciben las mismas solicitudes;
  - con aceptación 0, la política con sugerencias es idéntica a la agenda fija;
  - en temporada alta baja la espera y en baja bajan los ociosos (IC95 bajo cero);
  - RN-35 se cumple y con 8 lugares no hay sobrecupo;
  - el modelo aprende cuando la asistencia informada está mal;
  - Poisson, percentiles y cuantiles t;
  - el formato de los CSV.
- `InformeSimulacionTest` (1): genera los CSV en cada `mvn verify`, en aproximadamente 1 s con 20 réplicas.
- `mvn verify`: 302 pruebas, 0 fallas. El jar no tiene clases ni recursos de la simulación.

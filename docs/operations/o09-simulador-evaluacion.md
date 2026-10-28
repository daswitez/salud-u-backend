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

Cada fila empieza con `origen=SIMULACION`, la fecha de ejecución, las versiones (simulador o09-v2, estimador o03-v1 y sugeridor o04-v1), la semilla, las réplicas y los parámetros.

- `simulacion-o09-detalle-<fecha>.csv`: una fila por réplica, especialidad, tramo y política.
- `simulacion-o09-resumen-<fecha>.csv`: el promedio de las réplicas y, para la política con sugerencias, la diferencia pareada contra la agenda fija en ociosos y espera, con su IC95 (t de Student).
  - **Criterio** según la temporada: en BAJA, menos ociosos; en ALTA, menos espera; en todas, sobrecarga ≤ 0,20.
  - **Veredicto:** `SI` si todo el intervalo favorece al componente, `NO` si lo contradice y `NO_CONCLUYENTE` si incluye el cero.

La corrida de referencia está en `docs/evaluacion/`. Usa **valores de ejemplo** que hay que reemplazar por los que informe el personal; siempre se presenta como simulación.

## 4. Hallazgos históricos de la corrida anterior (no representan el área)

La siguiente corrida anterior usó Odontología y Psicología como ejemplos genéricos; esas especialidades no pertenecen al área y no deben presentarse como su situación. Se conserva solo como registro histórico de O-09.

- **Temporada alta:** la espera baja de forma significativa (Odontología −3,4 días; Psicología en exámenes −2,2 días), a costa de algunos cupos ociosos más por las jornadas adicionales.
- **Temporada baja:** los ociosos bajan (Odontología −22 puntos; Psicología −8), pero **la espera sube** (+2,6 y +1,4 días), porque se liberan jornadas.
- **Sobrecarga:** entre 0 % y 2,2 % de las jornadas en todos los tramos, muy por debajo del 20 %.
- **Sobrecupo sin demanda:** el sobrecupo se sugiere solo por el riesgo de asistencia, sin mirar la demanda. En temporada normal sube los ociosos (Odontología en clases +11 puntos), aunque acorta la espera.
- **Calibración:** cuando la asistencia informada difiere poco de la real (0,80 contra 0,75), el Brier del modelo queda prácticamente igual al de la línea base, y a veces apenas peor. El ruido de estimar por médico, día de la semana y tipo de período pesa más que el sesgo que corrige. Cuando difiere mucho (0,9 contra 0,6), el modelo es claramente mejor; hay una prueba de esto.
- **Demanda:** el error absoluto medio del modelo es menor que repetir la semana anterior en todos los tramos.
- **RN-35:** con menos de 10 lugares por jornada, ⌊C × 1,10⌋ = C y no hay sobrecupo posible.

## 5. Evidencia

- `SimuladorAgendaTest` (históricamente 6; ahora incluye pruebas adicionales del perfil):
  - la misma semilla da la misma corrida y las dos políticas reciben las mismas solicitudes;
  - con aceptación 0, la política con sugerencias es idéntica a la agenda fija;
  - en temporada alta baja la espera y en baja bajan los ociosos (IC95 bajo cero);
  - RN-35 se cumple y con 8 lugares no hay sobrecupo;
  - el modelo aprende cuando la asistencia informada está mal;
  - Poisson, percentiles y cuantiles t;
  - el formato de los CSV.
- `InformeSimulacionTest` (1): genera los CSV en cada `mvn verify`, en aproximadamente 1 s con 20 réplicas.
- `mvn verify`: 302 pruebas, 0 fallas. El jar no tiene clases ni recursos de la simulación.


## 6. SIM-ESPECIALIDADES · primera corrida histórica con valores de ejemplo

La versión `o09-v2` agrega la columna opcional `perfil_semana`: cinco multiplicadores separados por `;`, de lunes a viernes, finitos y no negativos. Si falta la columna o la celda está vacía, el perfil es `1;1;1;1;1`, conservando las mismas llegadas de la versión anterior para la misma semilla y escenario. Para cada día la media Poisson es `demanda_diaria × multiplicador`; los números aleatorios generados se comparten entre ambas políticas. El perfil se aplica también a los tramos de calentamiento y enfriamiento.

La agenda **Revisión médica** representa atención general con `id_especialidad = NULL`; las otras agendas de ejemplo son Ginecología, Medicina interna, Urología, Oftalmología y Dermatología. Se incluyen cuatro períodos por agenda y 20 réplicas con semilla 20261027. Hay tres médicos de revisión con 12 lugares por jornada; las especialidades tienen 1–2 médicos y menos de 10 lugares por jornada, por lo que RN-35 no permite sobrecupo en ninguna. Las demandas, asistencias, pesos y perfiles son **valores de ejemplo**, no datos obtenidos del área.

Un **día saturado** es un día hábil medido en que las solicitudes nuevas de ese día superan la suma de la capacidad publicada para esa fecha por la política, incluidas jornadas adicionales o liberaciones y sobrecupos. Cuenta días, no médicos, y no debe confundirse con la sobrecarga: esta mide jornadas en las que los pacientes que efectivamente asisten superan la capacidad definida. La comparación usa capacidad total de la fecha, no los lugares libres descontando reservas previas; así se mide presión diaria de entrada frente a capacidad diaria. La acumulación de solicitudes pendientes y la espera se miden aparte.

Además del detalle y resumen habituales se produce `simulacion-o09-indicadores-<fecha>.csv` con tasa de ociosos, espera media, días saturados, tasa de sobrecarga, Brier y MAE de demanda. Cada indicador tiene media e IC95 t de Student sobre réplicas. El archivo incluye diferencias pareadas con IC95: sugerencias menos agenda fija para ociosidad, espera y días saturados; Brier menos asistencia inicial y MAE menos semana anterior para ambas políticas. Un IC de diferencia totalmente negativo recibe `SI`, uno totalmente positivo `NO`, uno que incluye cero `NO_CONCLUYENTE`, y un tamaño insuficiente `SIN_DATOS`. Para sobrecarga, `SI` significa que todo el IC95 de la tasa está en o debajo de 0,20; `NO` que está por encima y `NO_CONCLUYENTE` que cruza el límite. Son criterios de evaluación de la simulación y no acreditan desempeño real.

La primera corrida identificada se conserva en `../../../../ENTREGAS_CODEX/SIM-ESPECIALIDADES/corrida-ejemplo-1729/resumen.md` y sus CSV históricos se conservan. Para repetir con datos reales cuando se reciban, usar un archivo de escenarios separado, indicar su fuente y fecha, y guardar la nueva corrida aparte; no sobrescribir ni presentar los ejemplos como mediciones del área.


## 7. Volúmenes informados por el centro, no medidos

La nueva corrida utiliza los rangos comunicados el 27/10/2026: revisión general de hasta 60 estudiantes en días normales y entre 100 y 150 en días de alta demanda concentrados en junio y julio; especialistas entre 5 y 15 por día. Es información declarada por el centro, no una serie de mediciones. No se incorpora el pico de 200 asociado a campañas ni se simula vacunación. La distribución Poisson genera conteos aleatorios sin límite rígido: su media representa el escenario, no un máximo garantizado.

Las entradas no informadas se mantienen como **supuestos de simulación**, en particular tres médicos de revisión, 12 lugares por jornada y médico, el perfil semanal, los valores de asistencia y peso, la demanda concreta por especialidad y las capacidades: Ginecología y Medicina interna tienen un médico y 15 lugares; Urología, Oftalmología y Dermatología tienen un médico y 5 lugares. Solo se afirma que las dos especialidades de 15 podrían admitir sobrecupo bajo RN-35; las tres de 5 no lo admiten.

No había un calendario académico de junio–julio de 2027 cargado al preparar la corrida. Se asume provisionalmente clases en junio (y hasta el 2 de julio) y exámenes desde el 5 hasta el 30 de julio. Se divide el tramo de clases en normal y alta para concentrar el pico en esas semanas; el supuesto debe corregirse con el calendario confirmado del área. El área de revisión usa `id_especialidad = NULL`. En las filas de alta, `demanda_diaria` es 80 y se multiplica por `1.7;1.2;1;0.6;0.3`: la media del lunes es 136, y la variabilidad del resto de días es una hipótesis, no una medición diaria. El valor inicial de estimación para clases se conserva del primer tramo de ese tipo; el modelo aprende de las observaciones posteriores, incluso en alta.

La corrida, sus intervalos y las diferencias frente a sus líneas base se documentan en `../../../../ENTREGAS_CODEX/SIM-ESPECIALIDADES/resumen.md`. Se conservaron por separado la corrida de ejemplos anterior y sus resultados. Cuando se reciban series medidas, asistencia o calendario confirmado, se efectuará otra corrida sin sobrescribir ninguna de estas.

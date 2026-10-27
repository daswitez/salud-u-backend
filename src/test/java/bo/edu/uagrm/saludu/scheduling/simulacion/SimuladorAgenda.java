package bo.edu.uagrm.saludu.scheduling.simulacion;

import bo.edu.uagrm.saludu.scheduling.application.EstimadorAgenda;
import bo.edu.uagrm.saludu.scheduling.application.EvaluadorAgenda;
import bo.edu.uagrm.saludu.scheduling.application.SugeridorAgenda;
import java.nio.charset.StandardCharsets;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.time.temporal.TemporalAdjusters;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Deque;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Random;
import java.util.UUID;

/**
 * O-09: simulación de jornadas para la primera etapa de la evaluación (sección 3.5, cuadro 3.70). Vive solo en
 * {@code src/test}: no se empaqueta ni se expone.
 *
 * <p>Por especialidad se generan semanas sintéticas con los valores de cada tramo: llegadas diarias de solicitudes
 * Poisson(demanda) y, por solicitud, un número uniforme que decide si el paciente llega (u &lt; asistencia real). Las
 * mismas llegadas y asistencias se usan en las dos políticas (números aleatorios comunes), de modo que la diferencia
 * solo viene de la agenda:
 * <ul>
 *   <li>{@link #AGENDA_FIJA}: cada médico publica cada día hábil su capacidad, con {@code horizonte} días hábiles de
 *       anticipación; las solicitudes se asignan en orden de llegada al primer lugar libre.</li>
 *   <li>{@link #CON_SUGERENCIAS}: lo mismo, pero cada noche corre {@link EstimadorAgenda} con las jornadas cerradas y
 *       {@link SugeridorAgenda} propone el sobrecupo de cada jornada que entra al horizonte. Los lunes Administración
 *       revisa la alerta de capacidad: con exceso agrega jornadas adicionales y con defecto libera jornadas sin citas.
 *       Cada sugerencia se acepta con probabilidad {@code aceptacion}.</li>
 * </ul>
 * Las métricas siguen las definiciones de O-08 y la calibración usa {@link EvaluadorAgenda}. Los avisos no se simulan.
 */
public final class SimuladorAgenda {
    public static final String VERSION = "o09-v1";
    public static final String AGENDA_FIJA = "AGENDA_FIJA", CON_SUGERENCIAS = "CON_SUGERENCIAS";
    private static final ZoneOffset BOLIVIA = ZoneOffset.ofHours(-4);

    /** Semanas seguidas de una especialidad con un tipo de período (código de API, como en valor_inicial_agenda). */
    public record Tramo(String especialidad, int medicos, int capacidadJornada, String tipoPeriodo, String temporada, int semanas,
        double demandaDiaria, double asistenciaEsperada, int pesoCitas, double asistenciaReal) {}

    public record Parametros(long semilla, int replicas, double aceptacion, int horizonte, int semanasCalentamiento,
        int jornadasAdicionalesSemanales, LocalDate inicio) {
        public static Parametros porDefecto() { return new Parametros(20261027L, 20, 1.0, 10, 2, 2, LocalDate.parse("2027-02-01")); }

        public String descripcion() {
            return String.format(Locale.ROOT, "aceptacion=%.2f;horizonte_dias_habiles=%d;semanas_calentamiento=%d;jornadas_adicionales_semanales=%d;inicio=%s;riesgo_maximo=%.2f;sobrecupo_maximo_pct=%d",
                aceptacion, horizonte, semanasCalentamiento, jornadasAdicionalesSemanales, inicio, SugeridorAgenda.RIESGO_MAXIMO, SugeridorAgenda.SOBRECUPO_MAXIMO_PORCENTAJE);
        }
    }

    /** Resultado de una política en un tramo de una réplica. Un indicador sin datos es null, como en O-08. */
    public record Fila(int replica, String especialidad, String tipoPeriodo, String temporada, LocalDate desde, LocalDate hasta,
        String politica, int solicitudes, int jornadas, int lugaresPublicados, int lugaresOciosos, Double tasaOciosos,
        int solicitudesAsignadas, Double esperaPromedio, Double esperaMediana, Double esperaP90, int jornadasSobrecargadas,
        Double tasaSobrecarga, double sobrecupoMaximo, int citasEvaluadas, Double brier, Double brierBase, int diasDemanda,
        Double errorDemanda, Double errorDemandaBase, int sugerenciasEmitidas, int sugerenciasAceptadas, int jornadasAdicionales,
        int jornadasLiberadas, int pendientesAlFinal) {}

    private record Dia(LocalDate fecha, Tramo tramo, int indiceTramo) {}

    private record Solicitud(int dia, double azar) {}

    private record Clave(UUID idEspecialidad, UUID idPersonal, int diaSemana, String tipoPeriodo) {}

    private static final class Jornada {
        int definida, capacidad;
        boolean decidida, liberada, adicional;
        final List<Solicitud> reservas = new ArrayList<>();
        int libres() { return capacidad - reservas.size(); }
    }

    /** Acumulado de un tramo (los días de calentamiento y enfriamiento tienen índice -1 y no se miden). */
    private static final class Medida {
        int solicitudes, jornadas, publicados, ociosos, sobrecargadas, emitidas, aceptadas, adicionales, liberadas, pendientes;
        double sobrecupoMaximo;
        final List<Double> esperas = new ArrayList<>();
    }

    private final EstimadorAgenda estimador = new EstimadorAgenda();
    private final EvaluadorAgenda evaluador = new EvaluadorAgenda();
    private final SugeridorAgenda sugeridor = new SugeridorAgenda();

    /** Todas las réplicas, especialidades, tramos y políticas. */
    public List<Fila> simular(List<Tramo> tramos, Parametros parametros) {
        Map<String, List<Tramo>> porEspecialidad = new LinkedHashMap<>();
        for (Tramo tramo : tramos) porEspecialidad.computeIfAbsent(tramo.especialidad(), e -> new ArrayList<>()).add(tramo);
        List<Fila> filas = new ArrayList<>();
        for (int replica = 1; replica <= parametros.replicas(); replica++)
            for (List<Tramo> especialidad : porEspecialidad.values()) filas.addAll(replica(especialidad, parametros, replica));
        return filas;
    }

    List<Fila> replica(List<Tramo> tramos, Parametros p, int replica) {
        String nombre = tramos.getFirst().especialidad();
        UUID especialidad = UUID.nameUUIDFromBytes(nombre.getBytes(StandardCharsets.UTF_8));
        List<Dia> dias = calendario(tramos, p);
        Random azar = new Random(Objects.hash(p.semilla(), replica, nombre));
        List<List<Solicitud>> llegadas = new ArrayList<>();
        for (int t = 0; t < dias.size(); t++) {
            List<Solicitud> delDia = new ArrayList<>();
            for (int i = poisson(azar, dias.get(t).tramo().demandaDiaria()); i > 0; i--) delDia.add(new Solicitud(t, azar.nextDouble()));
            llegadas.add(delDia);
        }
        List<EstimadorAgenda.ValorInicial> iniciales = new ArrayList<>();
        Map<String, Boolean> vistos = new HashMap<>();
        for (Tramo t : tramos)
            if (vistos.putIfAbsent(t.tipoPeriodo(), true) == null)
                iniciales.add(new EstimadorAgenda.ValorInicial(especialidad, t.tipoPeriodo(), t.demandaDiaria(), t.asistenciaEsperada(), t.pesoCitas()));
        List<Fila> filas = new ArrayList<>();
        for (String politica : List.of(AGENDA_FIJA, CON_SUGERENCIAS))
            filas.addAll(correr(politica, replica, especialidad, tramos, dias, llegadas, iniciales, p,
                new Random(Objects.hash(p.semilla(), replica, nombre, "decisiones"))));
        return filas;
    }

    private List<Fila> correr(String politica, int replica, UUID especialidad, List<Tramo> tramos, List<Dia> dias,
        List<List<Solicitud>> llegadas, List<EstimadorAgenda.ValorInicial> iniciales, Parametros p, Random decisiones) {
        boolean sugerencias = CON_SUGERENCIAS.equals(politica);
        int medicos = tramos.stream().mapToInt(Tramo::medicos).max().orElse(0);
        UUID[] personal = new UUID[medicos];
        for (int m = 0; m < medicos; m++) personal[m] = UUID.nameUUIDFromBytes((especialidad + "#" + m).getBytes(StandardCharsets.UTF_8));
        Jornada[][] agenda = new Jornada[dias.size()][medicos];
        for (int t = 0; t < dias.size(); t++)
            for (int m = 0; m < medicos; m++) {
                agenda[t][m] = new Jornada();
                if (m < dias.get(t).tramo().medicos()) agenda[t][m].definida = agenda[t][m].capacidad = dias.get(t).tramo().capacidadJornada();
            }
        Medida[] medidas = new Medida[tramos.size()];
        for (int i = 0; i < medidas.length; i++) medidas[i] = new Medida();
        List<EstimadorAgenda.Observacion> observaciones = new ArrayList<>();
        Deque<Solicitud> pendientes = new ArrayDeque<>();

        for (int t = 0; t < dias.size(); t++) {
            Dia hoy = dias.get(t);
            int ultimo = Math.min(t + p.horizonte(), dias.size() - 1);
            if (sugerencias) {
                Map<Clave, EstimadorAgenda.Estimacion> vigentes = new HashMap<>();
                for (EstimadorAgenda.Estimacion e : estimador.estimar(observaciones, iniciales))
                    vigentes.put(new Clave(e.idEspecialidad(), e.idPersonal(), e.diaSemana(), e.tipoPeriodo()), e);
                for (int k = t + 1; k <= ultimo; k++)
                    for (int m = 0; m < medicos; m++)
                        sobrecupo(agenda[k][m], dias.get(k), especialidad, personal[m], vigentes, iniciales, p, decisiones, medida(medidas, dias.get(k)));
                if (hoy.fecha().getDayOfWeek() == DayOfWeek.MONDAY && ultimo > t)
                    alerta(agenda, dias, t, ultimo, especialidad, pendientes.size(), vigentes, p, decisiones, medida(medidas, hoy));
            }
            Medida medidaHoy = medida(medidas, hoy);
            if (medidaHoy != null) medidaHoy.solicitudes += llegadas.get(t).size();
            pendientes.addAll(llegadas.get(t));
            asignar(pendientes, agenda, dias, t, ultimo, medidaHoy);

            int capacidadDia = 0, asistenciasDia = 0, ausenciasDia = 0;
            for (int m = 0; m < medicos; m++) {
                Jornada j = agenda[t][m];
                if (j.capacidad == 0) continue;
                int asistencias = 0;
                for (Solicitud s : j.reservas) if (s.azar() < hoy.tramo().asistenciaReal()) asistencias++;
                int ausencias = j.reservas.size() - asistencias;
                observaciones.add(new EstimadorAgenda.Observacion(hoy.fecha(), personal[m], especialidad, hoy.tramo().tipoPeriodo(),
                    j.capacidad, asistencias, ausencias, null));
                capacidadDia += j.capacidad;
                asistenciasDia += asistencias;
                ausenciasDia += ausencias;
                if (medidaHoy != null) {
                    medidaHoy.jornadas++;
                    medidaHoy.publicados += j.capacidad;
                    medidaHoy.ociosos += Math.max(j.capacidad - asistencias, 0);
                    if (asistencias > j.definida) medidaHoy.sobrecargadas++;
                    medidaHoy.sobrecupoMaximo = Math.max(medidaHoy.sobrecupoMaximo, (double) j.capacidad / j.definida - 1);
                }
            }
            observaciones.add(new EstimadorAgenda.Observacion(hoy.fecha(), null, especialidad, hoy.tramo().tipoPeriodo(),
                capacidadDia, asistenciasDia, ausenciasDia, llegadas.get(t).size()));
            if (medidaHoy != null) medidaHoy.pendientes = pendientes.size();
        }

        List<Fila> filas = new ArrayList<>();
        for (int i = 0; i < tramos.size(); i++) {
            Tramo tramo = tramos.get(i);
            int indice = i;
            List<Dia> delTramo = dias.stream().filter(d -> d.indiceTramo() == indice).toList();
            LocalDate desde = delTramo.getFirst().fecha(), hasta = delTramo.getLast().fecha();
            Medida m = medidas[i];
            EvaluadorAgenda.Evaluacion evaluacion = evaluador.evaluar(observaciones, iniciales, desde, hasta);
            List<Double> esperas = new ArrayList<>(m.esperas);
            Collections.sort(esperas);
            filas.add(new Fila(replica, tramo.especialidad(), tramo.tipoPeriodo(), tramo.temporada(), desde, hasta, politica,
                m.solicitudes, m.jornadas, m.publicados, m.ociosos, razon(m.ociosos, m.publicados), esperas.size(),
                esperas.isEmpty() ? null : esperas.stream().mapToDouble(Double::doubleValue).average().orElseThrow(),
                percentil(esperas, 0.5), percentil(esperas, 0.9), m.sobrecargadas, razon(m.sobrecargadas, m.jornadas), m.sobrecupoMaximo,
                evaluacion.calibracion().citas(), evaluacion.calibracion().brier(), evaluacion.calibracion().brierBase(),
                evaluacion.demanda().dias(), evaluacion.demanda().errorMedio(), evaluacion.demanda().errorMedioBase(),
                m.emitidas, m.aceptadas, m.adicionales, m.liberadas, m.pendientes));
        }
        return filas;
    }

    /** Sobrecupo de una jornada al entrar al horizonte, con la estimación vigente (O-04), decidido una sola vez. */
    private void sobrecupo(Jornada j, Dia dia, UUID especialidad, UUID personal, Map<Clave, EstimadorAgenda.Estimacion> vigentes,
        List<EstimadorAgenda.ValorInicial> iniciales, Parametros p, Random decisiones, Medida medida) {
        if (j.decidida || j.liberada || j.definida == 0) return;
        j.decidida = true;
        int diaSemana = dia.fecha().getDayOfWeek().getValue();
        String tipo = dia.tramo().tipoPeriodo();
        EstimadorAgenda.Estimacion e = null;
        for (Clave clave : List.of(new Clave(especialidad, personal, diaSemana, tipo), new Clave(especialidad, null, diaSemana, tipo),
                new Clave(null, null, diaSemana, tipo)))
            if (e == null) e = vigentes.get(clave);
        double alfa, beta;
        String fuente;
        if (e != null) { alfa = e.alfaVigente(); beta = e.betaVigente(); fuente = e.fuenteVigente(); }
        else {
            EstimadorAgenda.ValorInicial v = iniciales.stream().filter(i -> i.tipoPeriodo().equals(tipo)).findFirst().orElseThrow();
            alfa = v.peso() * v.asistencia();
            beta = v.peso() * (1 - v.asistencia());
            fuente = EstimadorAgenda.INITIAL_VALUE;
        }
        List<SugeridorAgenda.Cupo> cupos = new ArrayList<>();
        OffsetDateTime inicio = dia.fecha().atTime(8, 0).atOffset(BOLIVIA);
        for (int i = 0; i < j.definida; i++) cupos.add(new SugeridorAgenda.Cupo(UUID.randomUUID(), inicio.plusMinutes(30L * i), 1, 0));
        for (SugeridorAgenda.Sugerencia s : sugeridor.jornada(new SugeridorAgenda.Jornada(dia.fecha(), personal, especialidad, inicio,
                cupos, alfa, beta, fuente, false))) {
            if (!SugeridorAgenda.OVERBOOKING.equals(s.tipo())) continue;
            if (medida != null) medida.emitidas++;
            if (decisiones.nextDouble() < p.aceptacion()) {
                j.capacidad += ((Number) s.valor().get("sobrecupo")).intValue();
                if (medida != null) medida.aceptadas++;
            }
        }
    }

    /** Alerta de capacidad de los lunes: con exceso agrega jornadas, con defecto libera jornadas sin citas. */
    private void alerta(Jornada[][] agenda, List<Dia> dias, int t, int ultimo, UUID especialidad, int pendientes,
        Map<Clave, EstimadorAgenda.Estimacion> vigentes, Parametros p, Random decisiones, Medida medida) {
        int publicados = 0, libres = 0;
        double demanda = 0;
        for (int k = t + 1; k <= ultimo; k++) {
            Dia dia = dias.get(k);
            for (Jornada j : agenda[k]) { publicados += j.capacidad; libres += Math.max(j.libres(), 0); }
            EstimadorAgenda.Estimacion e = vigentes.get(new Clave(especialidad, null, dia.fecha().getDayOfWeek().getValue(), dia.tramo().tipoPeriodo()));
            demanda += e != null && e.demandaSuavizada() != null ? e.demandaSuavizada() : dia.tramo().demandaDiaria();
        }
        Optional<SugeridorAgenda.Sugerencia> alerta = sugeridor.alerta(new SugeridorAgenda.DemandaEspecialidad(especialidad, pendientes,
            publicados, libres, demanda, ultimo - t, 0), dias.get(t + 1).fecha(), dias.get(ultimo).fecha());
        if (alerta.isEmpty()) return;
        if (medida != null) medida.emitidas++;
        if (decisiones.nextDouble() >= p.aceptacion()) return;
        if (medida != null) medida.aceptadas++;
        double proyectada = pendientes + demanda;
        if (Boolean.TRUE.equals(alerta.get().valor().get("exceso_demanda"))) {
            int agregadas = 0;
            for (int k = t + 1; k <= ultimo && agregadas < p.jornadasAdicionalesSemanales() && libres < proyectada; k++)
                for (Jornada j : agenda[k]) {
                    if (agregadas >= p.jornadasAdicionalesSemanales() || libres >= proyectada) break;
                    if (j.definida == 0 || j.adicional || j.liberada) continue;
                    int extra = dias.get(k).tramo().capacidadJornada();
                    j.adicional = true;
                    j.definida += extra;
                    j.capacidad += extra;
                    libres += extra;
                    agregadas++;
                    if (medida != null) medida.adicionales++;
                }
        } else {
            for (int k = ultimo; k > t; k--)
                for (Jornada j : agenda[k]) {
                    if (j.liberada || j.capacidad == 0 || !j.reservas.isEmpty() || libres - j.capacidad < proyectada) continue;
                    libres -= j.capacidad;
                    j.liberada = true;
                    j.capacidad = j.definida = 0;
                    if (medida != null) medida.liberadas++;
                }
        }
    }

    /** Orden de llegada al primer lugar libre del horizonte; la espera se mide en días de calendario. */
    private static void asignar(Deque<Solicitud> pendientes, Jornada[][] agenda, List<Dia> dias, int t, int ultimo, Medida medida) {
        while (!pendientes.isEmpty()) {
            Jornada destino = null;
            int dia = -1;
            for (int k = t + 1; k <= ultimo && destino == null; k++)
                for (Jornada j : agenda[k]) if (j.libres() > 0) { destino = j; dia = k; break; }
            if (destino == null) return;
            Solicitud s = pendientes.removeFirst();
            destino.reservas.add(s);
            if (medida != null) medida.esperas.add((double) ChronoUnit.DAYS.between(dias.get(s.dia()).fecha(), dias.get(dia).fecha()));
        }
    }

    /**
     * Días hábiles. Antes de los tramos va el calentamiento con los valores del primero y después un enfriamiento del
     * largo del horizonte con los del último; ninguno se mide. El enfriamiento evita que las últimas solicitudes queden
     * pendientes solo porque la simulación se acaba.
     */
    private static List<Dia> calendario(List<Tramo> tramos, Parametros p) {
        List<Dia> dias = new ArrayList<>();
        LocalDate fecha = p.inicio().with(TemporalAdjusters.nextOrSame(DayOfWeek.MONDAY));
        for (int s = 0; s < p.semanasCalentamiento(); s++, fecha = fecha.plusWeeks(1))
            for (int d = 0; d < 5; d++) dias.add(new Dia(fecha.plusDays(d), tramos.getFirst(), -1));
        for (int i = 0; i < tramos.size(); i++)
            for (int s = 0; s < tramos.get(i).semanas(); s++, fecha = fecha.plusWeeks(1))
                for (int d = 0; d < 5; d++) dias.add(new Dia(fecha.plusDays(d), tramos.get(i), i));
        for (int s = 0; s < (p.horizonte() + 4) / 5; s++, fecha = fecha.plusWeeks(1))
            for (int d = 0; d < 5; d++) dias.add(new Dia(fecha.plusDays(d), tramos.getLast(), -1));
        return dias;
    }

    private static Medida medida(Medida[] medidas, Dia dia) { return dia.indiceTramo() < 0 ? null : medidas[dia.indiceTramo()]; }

    static int poisson(Random azar, double media) {
        double limite = Math.exp(-media), producto = azar.nextDouble();
        int k = 0;
        while (producto > limite) { producto *= azar.nextDouble(); k++; }
        return k;
    }

    /** Interpolación lineal, como percentile_cont de PostgreSQL. */
    static Double percentil(List<Double> ordenados, double fraccion) {
        if (ordenados.isEmpty()) return null;
        double posicion = fraccion * (ordenados.size() - 1);
        int abajo = (int) Math.floor(posicion), arriba = (int) Math.ceil(posicion);
        return ordenados.get(abajo) + (posicion - abajo) * (ordenados.get(arriba) - ordenados.get(abajo));
    }

    private static Double razon(int parte, int total) { return total == 0 ? null : (double) parte / total; }
}

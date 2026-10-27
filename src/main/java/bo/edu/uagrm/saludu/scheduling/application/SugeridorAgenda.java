package bo.edu.uagrm.saludu.scheduling.application;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * O-04: sugerencias de cupos por jornada, sobrecupo y alertas de capacidad, sin dependencias de Spring ni de la base.
 *
 * <p>Con capacidad C y asistencia Beta(α, β), las llegadas de N citas siguen una beta-binomial. Se sugiere el mayor N
 * entre C y ⌊C × 1,10⌋ (RN-35) tal que P(lleguen más de C) ≤ {@value #RIESGO_MAXIMO}. El sobrecupo N − C se aplica
 * subiendo la capacidad de los últimos cupos de la jornada, sin pasar de {@value #CAPACIDAD_MAXIMA_CUPO} por cupo.
 *
 * <p>La alerta compara la demanda proyectada de {@value #DIAS_HABILES} días hábiles (solicitudes pendientes más la
 * demanda estimada de cada día) con los lugares libres publicados: avisa sobre el 100 % o bajo el 50 %.
 */
public final class SugeridorAgenda {
    public static final String VERSION_MODELO = "o04-v1";
    public static final double RIESGO_MAXIMO = 0.20;
    public static final int SOBRECUPO_MAXIMO_PORCENTAJE = 10;
    public static final int CAPACIDAD_MAXIMA_CUPO = 20;
    public static final int DIAS_HABILES = 10;
    public static final double ALERTA_EXCESO = 100, ALERTA_DEFECTO = 50;
    /** Códigos de API del dominio tipo_sugerencia. */
    public static final String DAY_SLOTS = "DAY_SLOTS", OVERBOOKING = "OVERBOOKING", CAPACITY_ALERT = "CAPACITY_ALERT";

    private static final ZoneId BOLIVIA = ZoneId.of("America/La_Paz");
    private static final Locale ES = Locale.forLanguageTag("es-BO");
    private static final DateTimeFormatter DIA = DateTimeFormatter.ofPattern("dd/MM");

    public record Cupo(UUID id, OffsetDateTime iniciaA, int capacidad, int ocupados) {}

    /** fuente es el código de API de fuente_estimacion (DOCTOR, SPECIALTY, AREA o INITIAL_VALUE). */
    public record Jornada(LocalDate fecha, UUID idPersonal, UUID idEspecialidad, OffsetDateTime iniciaA, List<Cupo> cupos,
        double alfa, double beta, String fuente, boolean sobrecupoDecidido) {}

    public record DemandaEspecialidad(UUID idEspecialidad, int solicitudesPendientes, int cuposPublicados, int cuposLibres,
        double demandaEstimada, int diasHabiles, int diasSinEstimacion) {}

    /** valor lleva las claves internas en español; la base las traduce para la API. */
    public record Sugerencia(String tipo, LocalDate fecha, UUID idPersonal, UUID idEspecialidad, Map<String, Object> valor,
        String explicacion, OffsetDateTime venceEn) {}

    /** P(X > c) con X ~ BetaBinomial(n, α, β), por la recurrencia de la función de probabilidad. */
    public static double riesgoSaturacion(int n, int c, double alfa, double beta) {
        if (n <= c) return 0;
        double p = 1;
        for (int i = 0; i < n; i++) p *= (beta + i) / (alfa + beta + i);
        double cola = 0;
        for (int k = 0; k < n; k++) {
            if (k > c) cola += p;
            p *= (double) (n - k) / (k + 1) * (alfa + k) / (beta + n - k - 1);
        }
        return cola + p; // p es P(X = n) al salir del ciclo, y n > c.
    }

    /** El mayor N entre c y ⌊c × 1,10⌋ cuyo riesgo de saturación no supera el máximo. */
    public static int citasSugeridas(int c, double alfa, double beta) {
        int limite = c * (100 + SOBRECUPO_MAXIMO_PORCENTAJE) / 100, n = c;
        while (n < limite && riesgoSaturacion(n + 1, c, alfa, beta) <= RIESGO_MAXIMO) n++;
        return n;
    }

    /** Último día de una ventana de {@code dias} días hábiles (lunes a viernes) que empieza en {@code desde}. */
    public static LocalDate ultimoDiaHabil(LocalDate desde, int dias) {
        LocalDate dia = desde.minusDays(1);
        for (int contados = 0; contados < dias; ) {
            dia = dia.plusDays(1);
            if (dia.getDayOfWeek() != DayOfWeek.SATURDAY && dia.getDayOfWeek() != DayOfWeek.SUNDAY) contados++;
        }
        return dia;
    }

    public List<Sugerencia> jornada(Jornada jornada) {
        int capacidad = jornada.cupos().stream().mapToInt(Cupo::capacidad).sum();
        if (capacidad == 0 || jornada.sobrecupoDecidido()) return List.of();
        int limite = capacidad * (100 + SOBRECUPO_MAXIMO_PORCENTAJE) / 100;
        int sugeridas = citasSugeridas(capacidad, jornada.alfa(), jornada.beta());

        // El sobrecupo va a los últimos cupos, uno por cupo y en ronda, mientras tengan lugar bajo el máximo.
        List<Cupo> candidatos = new ArrayList<>(jornada.cupos());
        candidatos.sort(Comparator.comparing(Cupo::iniciaA).reversed().thenComparing(Cupo::id));
        Map<Cupo, Integer> extra = new LinkedHashMap<>();
        int pendientes = sugeridas - capacidad;
        boolean hayLugar = true;
        while (pendientes > 0 && hayLugar) {
            hayLugar = false;
            for (Cupo cupo : candidatos) {
                if (pendientes == 0) break;
                if (cupo.capacidad() + extra.getOrDefault(cupo, 0) < CAPACIDAD_MAXIMA_CUPO) {
                    extra.merge(cupo, 1, Integer::sum);
                    pendientes--;
                    hayLugar = true;
                }
            }
        }
        boolean sinLugar = pendientes > 0;
        sugeridas -= pendientes;
        double riesgo = riesgoSaturacion(sugeridas, capacidad, jornada.alfa(), jornada.beta());
        double asistencia = jornada.alfa() / (jornada.alfa() + jornada.beta());

        Map<String, Object> valor = new LinkedHashMap<>();
        valor.put("capacidad", capacidad);
        valor.put("citas_sugeridas", sugeridas);
        valor.put("riesgo_saturacion", decimal(riesgo, 4));
        valor.put("riesgo_maximo", decimal(RIESGO_MAXIMO, 2));
        valor.put("asistencia_estimada", decimal(asistencia, 3));
        String base = String.format(ES, "Capacidad de la jornada: %d lugares. Asistencia estimada: %s (%s). Con %d citas, la probabilidad de que lleguen más de %d pacientes es del %s (máximo %s).",
            capacidad, porcentaje(asistencia), fuente(jornada.fuente()), sugeridas, capacidad, porcentaje(riesgo), porcentaje(RIESGO_MAXIMO));
        String motivo;
        if (sugeridas > capacidad) motivo = String.format(ES, " Se sugiere un sobrecupo de %d %s (RN-35: hasta el %d %% de la capacidad).",
            sugeridas - capacidad, sugeridas - capacidad == 1 ? "cita" : "citas", SOBRECUPO_MAXIMO_PORCENTAJE);
        else if (limite == capacidad) motivo = String.format(ES, " El límite del %d %% no admite citas extra con esta capacidad (RN-35).", SOBRECUPO_MAXIMO_PORCENTAJE);
        else if (sinLugar) motivo = String.format(ES, " Los cupos ya están en su capacidad máxima de %d.", CAPACIDAD_MAXIMA_CUPO);
        else motivo = " Una cita más superaría el riesgo máximo.";
        List<Sugerencia> resultado = new ArrayList<>();
        resultado.add(new Sugerencia(DAY_SLOTS, jornada.fecha(), jornada.idPersonal(), jornada.idEspecialidad(), valor, base + motivo, jornada.iniciaA()));

        if (sugeridas > capacidad) {
            Map<String, Object> sobrecupo = new LinkedHashMap<>(valor);
            sobrecupo.put("sobrecupo", sugeridas - capacidad);
            List<Map<String, Object>> cupos = new ArrayList<>();
            extra.entrySet().stream().sorted(Comparator.comparing((Map.Entry<Cupo, Integer> e) -> e.getKey().iniciaA()))
                .forEach(e -> {
                    Map<String, Object> cupo = new LinkedHashMap<>();
                    cupo.put("id_cupo", e.getKey().id().toString());
                    cupo.put("inicia_a", e.getKey().iniciaA().toString());
                    cupo.put("capacidad_actual", e.getKey().capacidad());
                    cupo.put("capacidad_sugerida", e.getKey().capacidad() + e.getValue());
                    cupos.add(cupo);
                });
            sobrecupo.put("cupos", cupos);
            String explicacion = String.format(ES, "Subir la capacidad de %d %s para agendar %d %s más: con %d citas la probabilidad de que lleguen más de %d pacientes es del %s (máximo %s), con una asistencia estimada del %s (%s). No supera el %d %% de la capacidad definida (RN-35).",
                cupos.size(), cupos.size() == 1 ? "cupo" : "cupos", sugeridas - capacidad, sugeridas - capacidad == 1 ? "cita" : "citas",
                sugeridas, capacidad, porcentaje(riesgo), porcentaje(RIESGO_MAXIMO), porcentaje(asistencia), fuente(jornada.fuente()), SOBRECUPO_MAXIMO_PORCENTAJE);
            resultado.add(new Sugerencia(OVERBOOKING, jornada.fecha(), jornada.idPersonal(), jornada.idEspecialidad(), sobrecupo, explicacion, jornada.iniciaA()));
        }
        return resultado;
    }

    public Optional<Sugerencia> alerta(DemandaEspecialidad demanda, LocalDate desde, LocalDate hasta) {
        double proyectada = demanda.solicitudesPendientes() + demanda.demandaEstimada();
        Double porcentaje = demanda.cuposLibres() == 0 ? null : 100 * proyectada / demanda.cuposLibres();
        boolean exceso = porcentaje == null ? proyectada > 0 : porcentaje > ALERTA_EXCESO;
        boolean defecto = porcentaje != null && porcentaje < ALERTA_DEFECTO;
        if (!exceso && !defecto) return Optional.empty();

        Map<String, Object> valor = new LinkedHashMap<>();
        valor.put("desde", desde.toString());
        valor.put("hasta", hasta.toString());
        valor.put("dias_habiles", demanda.diasHabiles());
        valor.put("solicitudes_pendientes", demanda.solicitudesPendientes());
        valor.put("demanda_estimada", decimal(demanda.demandaEstimada(), 2));
        valor.put("demanda_proyectada", decimal(proyectada, 2));
        valor.put("cupos_publicados", demanda.cuposPublicados());
        valor.put("cupos_libres", demanda.cuposLibres());
        valor.put("porcentaje", porcentaje == null ? null : decimal(porcentaje, 1));
        valor.put("exceso_demanda", exceso);
        valor.put("dias_sin_estimacion", demanda.diasSinEstimacion());

        String inicio = String.format(ES, "En los próximos %d días hábiles (%s al %s) la demanda proyectada es de %s (%d solicitudes pendientes y %s estimadas)",
            demanda.diasHabiles(), DIA.format(desde), DIA.format(hasta), numero(proyectada), demanda.solicitudesPendientes(), numero(demanda.demandaEstimada()));
        String explicacion = porcentaje == null
            ? inicio + " y no hay lugares libres publicados. Conviene publicar una jornada."
            : exceso
                ? String.format(ES, "%s y hay %d lugares libres publicados: el %s. Conviene solicitar una jornada adicional.", inicio, demanda.cuposLibres(), numero(porcentaje) + " %")
                : String.format(ES, "%s y hay %d lugares libres publicados: el %s, menos de la mitad. Conviene liberar o reasignar horarios.", inicio, demanda.cuposLibres(), numero(porcentaje) + " %");
        if (demanda.diasSinEstimacion() > 0)
            explicacion += String.format(ES, " En %d %s se usó la capacidad publicada como demanda, porque aún no hay estimación (DV-10).",
                demanda.diasSinEstimacion(), demanda.diasSinEstimacion() == 1 ? "día" : "días");
        OffsetDateTime vence = desde.plusDays(1).atStartOfDay(BOLIVIA).toOffsetDateTime();
        return Optional.of(new Sugerencia(CAPACITY_ALERT, desde, null, demanda.idEspecialidad(), valor, explicacion, vence));
    }

    private static String fuente(String codigo) {
        return switch (codigo) {
            case "DOCTOR" -> "estimación del médico";
            case "SPECIALTY" -> "estimación de la especialidad";
            case "AREA" -> "estimación del área";
            default -> "valor inicial";
        };
    }

    private static String porcentaje(double proporcion) { return numero(100 * proporcion) + " %"; }

    private static String numero(double valor) {
        BigDecimal redondeado = BigDecimal.valueOf(valor).setScale(1, RoundingMode.HALF_UP).stripTrailingZeros();
        return redondeado.scale() <= 0 ? redondeado.setScale(0).toPlainString() : redondeado.toPlainString().replace('.', ',');
    }

    private static BigDecimal decimal(double valor, int escala) { return BigDecimal.valueOf(valor).setScale(escala, RoundingMode.HALF_UP); }
}

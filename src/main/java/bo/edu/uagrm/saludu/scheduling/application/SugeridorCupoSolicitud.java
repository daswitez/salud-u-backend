package bo.edu.uagrm.saludu.scheduling.application;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.stream.IntStream;

/**
 * O-05: ordena los cupos compatibles con una solicitud, sin dependencias de Spring ni de la base.
 *
 * <p>Costo de un cupo = w·espera + (1 − w)·ocupación, ambos entre 0 y 1:
 * <ul>
 *   <li>espera = días hasta el cupo / {@value #HORIZONTE_DIAS}, con tope 1;</li>
 *   <li>ocupación = asistentes esperados de la jornada si se agrega esta cita / su capacidad, con tope 1. Preferir
 *       la jornada menos cargada reparte el trabajo y llena antes las jornadas que quedarían ociosas;</li>
 *   <li>w depende de la prioridad de la derivación: cuanto más urgente, más pesa la espera.</li>
 * </ul>
 * Puntaje = 100·(1 − costo). Se devuelven los {@value #CANTIDAD} mejores.
 */
public final class SugeridorCupoSolicitud {
    public static final String VERSION_MODELO = "o05-v1";
    public static final int CANTIDAD = 3;
    public static final int HORIZONTE_DIAS = 30;

    private static final ZoneId BOLIVIA = ZoneId.of("America/La_Paz");
    private static final Locale ES = Locale.forLanguageTag("es-BO");
    private static final DateTimeFormatter CUANDO = DateTimeFormatter.ofPattern("EEEE dd/MM 'a las' HH:mm", ES);

    /** fuente es el código de API de fuente_estimacion. */
    public record Candidato(UUID idCupo, OffsetDateTime iniciaA, OffsetDateTime terminaA, UUID idPersonal, String nombrePersonal,
        UUID idEspecialidad, String nombreEspecialidad, int lugaresLibres, int capacidadJornada, int ocupadosJornada,
        double asistencia, String fuente) {}

    public record CupoSugerido(int orden, Candidato cupo, long diasEspera, double ocupacionEsperada, double puntaje, String explicacion) {}

    /** Peso de la espera según la prioridad (código de API); sin derivación, el de una derivación de rutina. */
    public static double pesoEspera(String prioridad) {
        if (prioridad == null) return 0.5;
        return switch (prioridad) {
            case "URGENT" -> 0.9;
            case "PRIORITY" -> 0.7;
            default -> 0.5;
        };
    }

    public List<CupoSugerido> ordenar(List<Candidato> candidatos, String prioridad, LocalDate hoy) {
        double w = pesoEspera(prioridad);
        record Evaluado(Candidato cupo, long dias, double ocupacion, double puntaje) {}
        List<Evaluado> evaluados = candidatos.stream().map(c -> {
            long dias = Math.max(0, ChronoUnit.DAYS.between(hoy, c.iniciaA().atZoneSameInstant(BOLIVIA).toLocalDate()));
            double espera = Math.min(1, (double) dias / HORIZONTE_DIAS);
            double ocupacion = Math.min(1, (c.ocupadosJornada() + 1) * c.asistencia() / c.capacidadJornada());
            double puntaje = redondear(100 * (1 - (w * espera + (1 - w) * ocupacion)), 1);
            return new Evaluado(c, dias, ocupacion, puntaje);
        }).sorted(Comparator.comparingDouble(Evaluado::puntaje).reversed()
            .thenComparing(e -> e.cupo().iniciaA()).thenComparing(e -> e.cupo().idCupo()))
            .limit(CANTIDAD).toList();
        return IntStream.range(0, evaluados.size()).mapToObj(i -> {
            Evaluado e = evaluados.get(i);
            return new CupoSugerido(i + 1, e.cupo(), e.dias(), redondear(e.ocupacion(), 3), e.puntaje(), explicar(e.cupo(), e.dias(), e.ocupacion(), e.puntaje(), prioridad, w));
        }).toList();
    }

    private static String explicar(Candidato c, long dias, double ocupacion, double puntaje, String prioridad, double w) {
        String espera = dias == 0 ? "hoy" : dias == 1 ? "en 1 día" : "en " + dias + " días";
        String prioridadTexto = switch (prioridad == null ? "" : prioridad) {
            case "URGENT" -> "Derivación urgente";
            case "PRIORITY" -> "Derivación prioritaria";
            case "ROUTINE" -> "Derivación de rutina";
            default -> "Solicitud sin derivación";
        };
        return String.format(ES, "%s con %s (%s). Con esta cita la jornada tendría %d de %d lugares ocupados y, con una asistencia estimada del %s (%s), una ocupación esperada del %s. %s: la espera pesa el %d %% y la ocupación el %d %%. Puntaje %s.",
            capitalizar(CUANDO.format(c.iniciaA().atZoneSameInstant(BOLIVIA))), c.nombrePersonal(), espera,
            c.ocupadosJornada() + 1, c.capacidadJornada(), porcentaje(c.asistencia()), fuente(c.fuente()), porcentaje(ocupacion),
            prioridadTexto, Math.round(100 * w), Math.round(100 * (1 - w)), numero(puntaje));
    }

    private static String fuente(String codigo) {
        return switch (codigo) {
            case "DOCTOR" -> "estimación del médico";
            case "SPECIALTY" -> "estimación de la especialidad";
            case "AREA" -> "estimación del área";
            default -> "valor inicial";
        };
    }

    private static String capitalizar(String texto) { return Character.toUpperCase(texto.charAt(0)) + texto.substring(1); }

    private static String porcentaje(double proporcion) { return numero(100 * proporcion) + " %"; }

    private static String numero(double valor) {
        BigDecimal redondeado = BigDecimal.valueOf(valor).setScale(1, RoundingMode.HALF_UP).stripTrailingZeros();
        return redondeado.scale() <= 0 ? redondeado.setScale(0).toPlainString() : redondeado.toPlainString().replace('.', ',');
    }

    private static double redondear(double valor, int escala) { return BigDecimal.valueOf(valor).setScale(escala, RoundingMode.HALF_UP).doubleValue(); }
}

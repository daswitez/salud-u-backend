package bo.edu.uagrm.saludu.scheduling.application;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * O-03: estimaciones de asistencia y demanda, sin dependencias de Spring ni de la base.
 *
 * <p>Para cada especialidad (null = área), médico (null = la especialidad completa), día de la semana y tipo de
 * período (null = fecha sin período), recorre las jornadas en orden de fecha:
 * {@code α ← λ·α + asistencias}, {@code β ← λ·β + ausencias} y, solo en la fila de la especialidad,
 * {@code D ← θ·d + (1 − θ)·D}, con d las solicitudes ingresadas. El punto de partida son los valores iniciales de
 * DV-10: {@code α₀ = peso·asistencia}, {@code β₀ = peso·(1 − asistencia)} y {@code D₀} la demanda esperada o, si
 * no se indicó, la capacidad de la primera jornada observada.
 *
 * <p>La asistencia vigente es la propia si reúne {@value #MINIMO_CITAS_PROPIAS} citas observadas; si no, la de la
 * especialidad y luego la del área; si ninguna llega, la propia, que todavía pesa sobre todo el valor inicial.
 */
public final class EstimadorAgenda {
    public static final String VERSION_MODELO = "o03-v1";
    public static final double FACTOR_OLVIDO = 0.95;
    public static final double SUAVIZADO_DEMANDA = 0.3;
    public static final int MINIMO_CITAS_PROPIAS = 20;
    public static final double ASISTENCIA_INICIAL = 0.8;
    public static final int PESO_INICIAL = 10;

    /** Fuentes de la asistencia vigente, con los códigos de API del dominio fuente_estimacion. */
    public static final String DOCTOR = "DOCTOR", SPECIALTY = "SPECIALTY", AREA = "AREA", INITIAL_VALUE = "INITIAL_VALUE";

    /** Una fila de observacion_jornada. solicitudes es null en las filas de médico. */
    public record Observacion(LocalDate fecha, UUID idPersonal, UUID idEspecialidad, String tipoPeriodo, int capacidad,
        int asistencias, int ausencias, Integer solicitudes) {}

    /** Una fila de valor_inicial_agenda. demanda null significa "igual a la capacidad publicada". */
    public record ValorInicial(UUID idEspecialidad, String tipoPeriodo, Double demanda, double asistencia, int peso) {}

    public record Estimacion(UUID idEspecialidad, UUID idPersonal, int diaSemana, String tipoPeriodo, double alfa, double beta,
        Double demandaSuavizada, int citasObservadas, int jornadasObservadas, LocalDate ultimaFecha,
        double asistenciaVigente, String fuenteVigente, double alfaVigente, double betaVigente) {
        public double asistenciaPropia() { return alfa / (alfa + beta); }
    }

    private record Clave(UUID idEspecialidad, UUID idPersonal, int diaSemana, String tipoPeriodo) {
        Clave especialidad() { return new Clave(idEspecialidad, null, diaSemana, tipoPeriodo); }
        Clave area() { return new Clave(null, null, diaSemana, tipoPeriodo); }
    }

    /** α y β del nivel elegido, que O-04 usa en la beta-binomial. */
    private record Vigente(double alfa, double beta, String fuente) {
        double asistencia() { return alfa / (alfa + beta); }
    }

    private static final class Acumulado {
        double alfa, beta;
        Double demanda;
        int citas, jornadas;
        LocalDate ultimaFecha;
    }

    public List<Estimacion> estimar(List<Observacion> observaciones, List<ValorInicial> valoresIniciales) {
        Map<String, ValorInicial> iniciales = new HashMap<>();
        for (ValorInicial valor : valoresIniciales) iniciales.put(claveInicial(valor.idEspecialidad(), valor.tipoPeriodo()), valor);

        List<Observacion> ordenadas = new ArrayList<>(observaciones);
        ordenadas.sort(Comparator.comparing(Observacion::fecha));
        Map<Clave, Acumulado> acumulados = new LinkedHashMap<>();
        for (Observacion observacion : ordenadas) {
            Clave clave = new Clave(observacion.idEspecialidad(), observacion.idPersonal(),
                observacion.fecha().getDayOfWeek().getValue(), observacion.tipoPeriodo());
            Acumulado acumulado = acumulados.computeIfAbsent(clave, ignored -> inicio(valorInicial(iniciales, clave), observacion));
            acumulado.alfa = FACTOR_OLVIDO * acumulado.alfa + observacion.asistencias();
            acumulado.beta = FACTOR_OLVIDO * acumulado.beta + observacion.ausencias();
            if (clave.idPersonal() == null)
                acumulado.demanda = SUAVIZADO_DEMANDA * observacion.solicitudes() + (1 - SUAVIZADO_DEMANDA) * acumulado.demanda;
            acumulado.citas += observacion.asistencias() + observacion.ausencias();
            acumulado.jornadas++;
            acumulado.ultimaFecha = observacion.fecha();
        }

        List<Estimacion> resultado = new ArrayList<>();
        acumulados.forEach((clave, acumulado) -> {
            Vigente vigente = vigente(acumulados, clave);
            resultado.add(new Estimacion(clave.idEspecialidad(), clave.idPersonal(), clave.diaSemana(), clave.tipoPeriodo(),
                acumulado.alfa, acumulado.beta, acumulado.demanda, acumulado.citas, acumulado.jornadas, acumulado.ultimaFecha,
                vigente.asistencia(), vigente.fuente(), vigente.alfa(), vigente.beta()));
        });
        return resultado;
    }

    /** Valor inicial de la especialidad y el tipo de período; si no hay, el del área; si tampoco, los de DV-10. */
    private static ValorInicial valorInicial(Map<String, ValorInicial> iniciales, Clave clave) {
        ValorInicial propio = iniciales.get(claveInicial(clave.idEspecialidad(), clave.tipoPeriodo()));
        if (propio != null) return propio;
        ValorInicial area = iniciales.get(claveInicial(null, clave.tipoPeriodo()));
        return area != null ? area : new ValorInicial(null, clave.tipoPeriodo(), null, ASISTENCIA_INICIAL, PESO_INICIAL);
    }

    private static Acumulado inicio(ValorInicial valor, Observacion primera) {
        Acumulado acumulado = new Acumulado();
        acumulado.alfa = valor.peso() * valor.asistencia();
        acumulado.beta = valor.peso() * (1 - valor.asistencia());
        if (primera.idPersonal() == null) acumulado.demanda = valor.demanda() != null ? valor.demanda() : (double) primera.capacidad();
        return acumulado;
    }

    private static Vigente vigente(Map<Clave, Acumulado> acumulados, Clave clave) {
        List<Clave> niveles = new ArrayList<>();
        if (clave.idPersonal() != null) niveles.add(clave);
        if (clave.idEspecialidad() != null) niveles.add(clave.especialidad());
        niveles.add(clave.area());
        for (Clave nivel : niveles) {
            Acumulado acumulado = acumulados.get(nivel);
            if (acumulado != null && acumulado.citas >= MINIMO_CITAS_PROPIAS)
                return new Vigente(acumulado.alfa, acumulado.beta, nivel.idPersonal() != null ? DOCTOR : nivel.idEspecialidad() != null ? SPECIALTY : AREA);
        }
        Acumulado propio = acumulados.get(clave);
        return new Vigente(propio.alfa, propio.beta, INITIAL_VALUE);
    }


    private static String claveInicial(UUID idEspecialidad, String tipoPeriodo) {
        return Objects.toString(idEspecialidad, "AREA") + "|" + Objects.toString(tipoPeriodo, "");
    }
}

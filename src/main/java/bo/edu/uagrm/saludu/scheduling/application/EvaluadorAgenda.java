package bo.edu.uagrm.saludu.scheduling.application;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.UUID;

/**
 * O-08 (cuadro 3.70): calibración de la asistencia y error de la demanda, sin dependencias de Spring ni de la base.
 *
 * <p>Para cada día evaluado se reconstruye lo que el modelo sabía la noche anterior: {@link EstimadorAgenda} con las
 * observaciones de días anteriores, igual que la tarea nocturna. Así cada pronóstico se compara con un resultado
 * que todavía no conocía.
 * <ul>
 *   <li>Brier = promedio por cita de (p − resultado)², con resultado 1 si asistió y 0 si faltó. Línea base: una
 *       asistencia constante igual al valor inicial.</li>
 *   <li>Error absoluto medio de la demanda diaria de cada especialidad. Línea base: las solicitudes del mismo día de
 *       la semana anterior, en los días que la tienen.</li>
 * </ul>
 */
public final class EvaluadorAgenda {
    private final EstimadorAgenda estimador = new EstimadorAgenda();

    public record Calibracion(int citas, Double brier, Double brierBase) {}

    public record ErrorDemanda(int dias, Double errorMedio, int diasComparables, Double errorMedioComparable, Double errorMedioBase) {}

    public record Evaluacion(Calibracion calibracion, ErrorDemanda demanda) {}

    private record Clave(UUID idEspecialidad, UUID idPersonal, int diaSemana, String tipoPeriodo) {}

    public Evaluacion evaluar(List<EstimadorAgenda.Observacion> observaciones, List<EstimadorAgenda.ValorInicial> iniciales,
        LocalDate desde, LocalDate hasta) {
        TreeMap<LocalDate, List<EstimadorAgenda.Observacion>> porDia = new TreeMap<>();
        for (EstimadorAgenda.Observacion o : observaciones) porDia.computeIfAbsent(o.fecha(), f -> new ArrayList<>()).add(o);
        Map<String, EstimadorAgenda.Observacion> demandaPorDia = new HashMap<>();
        for (EstimadorAgenda.Observacion o : observaciones)
            if (o.idPersonal() == null && o.solicitudes() != null) demandaPorDia.put(o.fecha() + "|" + o.idEspecialidad(), o);

        double brier = 0, brierBase = 0, error = 0, errorComparable = 0, errorBase = 0;
        int citas = 0, dias = 0, comparables = 0;
        List<EstimadorAgenda.Observacion> previas = new ArrayList<>();
        for (Map.Entry<LocalDate, List<EstimadorAgenda.Observacion>> dia : porDia.entrySet()) {
            LocalDate fecha = dia.getKey();
            if (!fecha.isBefore(desde) && !fecha.isAfter(hasta)) {
                Map<Clave, EstimadorAgenda.Estimacion> vigentes = new HashMap<>();
                for (EstimadorAgenda.Estimacion e : estimador.estimar(previas, iniciales))
                    vigentes.put(new Clave(e.idEspecialidad(), e.idPersonal(), e.diaSemana(), e.tipoPeriodo()), e);
                int diaSemana = fecha.getDayOfWeek().getValue();
                for (EstimadorAgenda.Observacion o : dia.getValue()) {
                    if (o.idPersonal() != null && o.asistencias() + o.ausencias() > 0) {
                        double p = asistencia(vigentes, iniciales, o, diaSemana), base = asistenciaInicial(iniciales, o.idEspecialidad(), o.tipoPeriodo());
                        brier += o.asistencias() * cuadrado(1 - p) + o.ausencias() * cuadrado(p);
                        brierBase += o.asistencias() * cuadrado(1 - base) + o.ausencias() * cuadrado(base);
                        citas += o.asistencias() + o.ausencias();
                    }
                    if (o.idPersonal() == null && o.solicitudes() != null) {
                        double diferencia = Math.abs(demanda(vigentes, iniciales, o, diaSemana) - o.solicitudes());
                        error += diferencia;
                        dias++;
                        EstimadorAgenda.Observacion semanaAnterior = demandaPorDia.get(fecha.minusWeeks(1) + "|" + o.idEspecialidad());
                        if (semanaAnterior != null) {
                            errorComparable += diferencia;
                            errorBase += Math.abs(semanaAnterior.solicitudes() - o.solicitudes());
                            comparables++;
                        }
                    }
                }
            }
            previas.addAll(dia.getValue());
        }
        return new Evaluacion(new Calibracion(citas, citas == 0 ? null : brier / citas, citas == 0 ? null : brierBase / citas),
            new ErrorDemanda(dias, dias == 0 ? null : error / dias, comparables,
                comparables == 0 ? null : errorComparable / comparables, comparables == 0 ? null : errorBase / comparables));
    }

    /** Igual que estimacion_vigente: médico, especialidad, área; sin estimación, el valor inicial. */
    private static double asistencia(Map<Clave, EstimadorAgenda.Estimacion> vigentes, List<EstimadorAgenda.ValorInicial> iniciales,
        EstimadorAgenda.Observacion o, int diaSemana) {
        for (Clave clave : List.of(new Clave(o.idEspecialidad(), o.idPersonal(), diaSemana, o.tipoPeriodo()),
                new Clave(o.idEspecialidad(), null, diaSemana, o.tipoPeriodo()), new Clave(null, null, diaSemana, o.tipoPeriodo()))) {
            EstimadorAgenda.Estimacion e = vigentes.get(clave);
            if (e != null) return e.asistenciaVigente();
        }
        return asistenciaInicial(iniciales, o.idEspecialidad(), o.tipoPeriodo());
    }

    private static double asistenciaInicial(List<EstimadorAgenda.ValorInicial> iniciales, UUID especialidad, String tipo) {
        EstimadorAgenda.ValorInicial area = null;
        for (EstimadorAgenda.ValorInicial v : iniciales) {
            if (tipo == null || !tipo.equals(v.tipoPeriodo())) continue;
            if (Objects.equals(v.idEspecialidad(), especialidad)) return v.asistencia();
            if (v.idEspecialidad() == null) area = v;
        }
        return area != null ? area.asistencia() : EstimadorAgenda.ASISTENCIA_INICIAL;
    }

    /** Igual que demanda_para_alertas: suavizada de la especialidad; si no, su valor inicial; si no, la capacidad (DV-10). */
    private static double demanda(Map<Clave, EstimadorAgenda.Estimacion> vigentes, List<EstimadorAgenda.ValorInicial> iniciales,
        EstimadorAgenda.Observacion o, int diaSemana) {
        EstimadorAgenda.Estimacion e = vigentes.get(new Clave(o.idEspecialidad(), null, diaSemana, o.tipoPeriodo()));
        if (e != null && e.demandaSuavizada() != null) return e.demandaSuavizada();
        for (EstimadorAgenda.ValorInicial v : iniciales)
            if (Objects.equals(v.idEspecialidad(), o.idEspecialidad()) && o.tipoPeriodo() != null && o.tipoPeriodo().equals(v.tipoPeriodo())
                && v.demanda() != null) return v.demanda();
        return o.capacidad();
    }

    private static double cuadrado(double valor) { return valor * valor; }
}

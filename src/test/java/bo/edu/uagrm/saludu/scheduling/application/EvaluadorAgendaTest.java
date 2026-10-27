package bo.edu.uagrm.saludu.scheduling.application;

import static bo.edu.uagrm.saludu.scheduling.application.EstimadorAgenda.*;
import static org.junit.jupiter.api.Assertions.*;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class EvaluadorAgendaTest {
    private static final double EPS = 1e-9;
    private static final UUID CARDIO = UUID.randomUUID(), MEDICO = UUID.randomUUID();
    private static final LocalDate MARTES = LocalDate.parse("2027-03-02");
    private final EvaluadorAgenda evaluador = new EvaluadorAgenda();

    @Test
    void withoutHistoryTheForecastIsTheInitialValueAndTheBrierScoreMatchesTheBaseline() {
        // p = 0,8: (4·0,2² + 1·0,8²) / 5 = 0,16.
        var calibracion = evaluador.evaluar(List.of(medico(MARTES, 4, 1)), List.of(), MARTES, MARTES).calibracion();
        assertEquals(5, calibracion.citas());
        assertEquals(0.16, calibracion.brier(), EPS);
        assertEquals(0.16, calibracion.brierBase(), EPS);
    }

    @Test
    void eachDayIsForecastOnlyWithEarlierDaysSoTheModelLearnsFromAbsences() {
        var dias = List.of(medico(MARTES, 4, 1), medico(MARTES.plusWeeks(1), 0, 10), medico(MARTES.plusWeeks(2), 0, 10),
            medico(MARTES.plusWeeks(3), 0, 10));
        var ultimo = evaluador.evaluar(dias, List.of(), MARTES.plusWeeks(3), MARTES.plusWeeks(3)).calibracion();
        assertEquals(10, ultimo.citas(), "Solo cuentan las citas del período; las anteriores son historia");
        assertEquals(0.64, ultimo.brierBase(), EPS, "Diez ausencias contra 0,8 constante");
        assertTrue(ultimo.brier() < ultimo.brierBase(), "Tras tres semanas de ausencias el modelo pronostica menos asistencia");
        // El pronóstico del día no puede usar ese mismo día: con todo el historial el error sería aún menor.
        var conElMismoDia = new EstimadorAgenda().estimar(dias, List.of()).getFirst().asistenciaVigente();
        assertTrue(Math.pow(conElMismoDia, 2) < ultimo.brier());
    }

    @Test
    void demandErrorUsesTheSmoothedForecastAndComparesWithTheSameWeekdayOfThePreviousWeek() {
        var iniciales = List.of(new ValorInicial(CARDIO, "CLASSES", 10.0, 0.8, 10));
        var dias = List.of(especialidad(MARTES, 4), especialidad(MARTES.plusWeeks(1), 7));
        // Martes 1: pronóstico 10 (valor inicial), error 6. Martes 2: 0,3·4 + 0,7·10 = 8,2, error 1,2; repetir da |4 − 7| = 3.
        var demanda = evaluador.evaluar(dias, iniciales, MARTES, MARTES.plusWeeks(1)).demanda();
        assertEquals(2, demanda.dias());
        assertEquals((6 + 1.2) / 2, demanda.errorMedio(), EPS);
        assertEquals(1, demanda.diasComparables());
        assertEquals(1.2, demanda.errorMedioComparable(), EPS);
        assertEquals(3.0, demanda.errorMedioBase(), EPS);

        var soloSegunda = evaluador.evaluar(dias, iniciales, MARTES.plusDays(1), MARTES.plusWeeks(1)).demanda();
        assertEquals(1, soloSegunda.dias());
        assertEquals(1.2, soloSegunda.errorMedio(), EPS);
        assertEquals(3.0, soloSegunda.errorMedioBase(), EPS, "La semana anterior sirve aunque esté fuera del período");
    }

    @Test
    void withoutDataEveryIndicatorIsNull() {
        var evaluacion = evaluador.evaluar(List.of(medico(MARTES, 4, 1)), List.of(), MARTES.plusDays(1), MARTES.plusDays(9));
        assertEquals(0, evaluacion.calibracion().citas());
        assertNull(evaluacion.calibracion().brier());
        assertNull(evaluacion.calibracion().brierBase());
        assertEquals(0, evaluacion.demanda().dias());
        assertNull(evaluacion.demanda().errorMedio());
        assertNull(evaluacion.demanda().errorMedioBase());
    }

    private static Observacion medico(LocalDate fecha, int asistencias, int ausencias) {
        return new Observacion(fecha, MEDICO, CARDIO, "CLASSES", asistencias + ausencias, asistencias, ausencias, null);
    }

    private static Observacion especialidad(LocalDate fecha, int solicitudes) {
        return new Observacion(fecha, null, CARDIO, "CLASSES", 8, 0, 0, solicitudes);
    }
}

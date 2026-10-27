package bo.edu.uagrm.saludu.scheduling.application;

import static bo.edu.uagrm.saludu.scheduling.application.EstimadorAgenda.*;
import static org.junit.jupiter.api.Assertions.*;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class EstimadorAgendaTest {
    private static final double EPS = 1e-9;
    private static final UUID CARDIO = UUID.randomUUID(), DERMA = UUID.randomUUID(), MEDICO = UUID.randomUUID(), OTRO = UUID.randomUUID();
    private static final LocalDate MARTES = LocalDate.parse("2027-03-02");
    private final EstimadorAgenda estimador = new EstimadorAgenda();

    @Test
    void pv73OneDayWithEightArrivalsAndTwoNoShowsAppliesTheForgettingFactorToTheDv10Prior() {
        // α₀ = 10·0,8 = 8 y β₀ = 10·0,2 = 2; α = 0,95·8 + 8 = 15,6 y β = 0,95·2 + 2 = 3,9.
        var fila = unica(estimador.estimar(List.of(medico(MARTES, MEDICO, CARDIO, "CLASSES", 12, 8, 2)), List.of()), MEDICO, CARDIO);
        assertEquals(15.6, fila.alfa(), EPS);
        assertEquals(3.9, fila.beta(), EPS);
        assertEquals(0.8, fila.asistenciaPropia(), EPS);
        assertEquals(10, fila.citasObservadas());
        assertEquals(1, fila.jornadasObservadas());
        assertEquals(2, fila.diaSemana(), "Día ISO: martes = 2");
        assertNull(fila.demandaSuavizada(), "La fila del médico no lleva demanda");
        assertEquals("o03-v1", VERSION_MODELO);
    }

    @Test
    void eachDayDecaysTheWholeHistoryInDateOrderRegardlessOfInputOrder() {
        var dias = List.of(medico(MARTES.plusWeeks(1), MEDICO, CARDIO, "CLASSES", 10, 3, 5),
            medico(MARTES, MEDICO, CARDIO, "CLASSES", 10, 9, 1));
        var fila = unica(estimador.estimar(dias, List.of()), MEDICO, CARDIO);
        // Primero (9, 1): α = 7,6 + 9 = 16,6; β = 1,9 + 1 = 2,9. Luego (3, 5): α = 15,77 + 3; β = 2,755 + 5.
        assertEquals(0.95 * (0.95 * 8 + 9) + 3, fila.alfa(), EPS);
        assertEquals(0.95 * (0.95 * 2 + 1) + 5, fila.beta(), EPS);
        assertEquals(MARTES.plusWeeks(1), fila.ultimaFecha());
        assertEquals(fila, unica(estimador.estimar(dias.reversed(), List.of()), MEDICO, CARDIO));
    }

    @Test
    void demandIsSmoothedOnlyOnSpecialtyRowsStartingFromTheInitialValueOrTheCapacity() {
        var dia = List.of(especialidad(MARTES, CARDIO, "CLASSES", 12, 0, 0, 4), especialidad(MARTES, DERMA, "CLASSES", 6, 0, 0, 9));
        var iniciales = List.of(new ValorInicial(CARDIO, "CLASSES", 10.0, 0.8, 10));
        var resultado = estimador.estimar(dia, iniciales);
        assertEquals(0.3 * 4 + 0.7 * 10, unica(resultado, null, CARDIO).demandaSuavizada(), EPS);
        // Sin demanda inicial, D₀ es la capacidad publicada de la primera jornada (DV-10).
        assertEquals(0.3 * 9 + 0.7 * 6, unica(resultado, null, DERMA).demandaSuavizada(), EPS);

        var dosDias = estimador.estimar(List.of(especialidad(MARTES, CARDIO, "CLASSES", 12, 0, 0, 4),
            especialidad(MARTES.plusWeeks(1), CARDIO, "CLASSES", 12, 0, 0, 0)), iniciales);
        assertEquals(0.7 * (0.3 * 4 + 0.7 * 10), unica(dosDias, null, CARDIO).demandaSuavizada(), EPS);
    }

    @Test
    void initialValuesComeFromTheSpecialtyThenTheAreaThenDv10Defaults() {
        var iniciales = List.of(new ValorInicial(CARDIO, "EXAMS", null, 0.5, 20), new ValorInicial(null, "EXAMS", null, 0.6, 5));
        var resultado = estimador.estimar(List.of(medico(MARTES, MEDICO, CARDIO, "EXAMS", 4, 0, 0),
            medico(MARTES, OTRO, DERMA, "EXAMS", 4, 0, 0), medico(MARTES, MEDICO, CARDIO, "CLASSES", 4, 0, 0)), iniciales);
        assertEquals(0.95 * 10, unica(resultado, MEDICO, CARDIO, "EXAMS").alfa(), EPS, "Especialidad: 20·0,5");
        assertEquals(0.95 * 3, unica(resultado, OTRO, DERMA, "EXAMS").alfa(), EPS, "Área: 5·0,6");
        assertEquals(0.95 * 8, unica(resultado, MEDICO, CARDIO, "CLASSES").alfa(), EPS, "DV-10: 10·0,8");
    }

    @Test
    void dayOfWeekAndPeriodTypeAreSeparateEstimates() {
        var resultado = estimador.estimar(List.of(medico(MARTES, MEDICO, CARDIO, "CLASSES", 4, 1, 0),
            medico(MARTES.plusDays(1), MEDICO, CARDIO, "CLASSES", 4, 1, 0), medico(MARTES, MEDICO, CARDIO, "EXAMS", 4, 1, 0),
            medico(MARTES, MEDICO, CARDIO, null, 4, 1, 0)), List.of());
        assertEquals(4, resultado.size());
        assertTrue(resultado.stream().allMatch(e -> e.jornadasObservadas() == 1));
    }

    @Test
    void withFewerThanTwentyObservedTheEstimateFallsBackToTheSpecialtyThenTheArea() {
        List<Observacion> dias = new ArrayList<>();
        // El médico observa 10 citas; su especialidad, 22 entre todos sus médicos; el área, 30.
        dias.add(medico(MARTES, MEDICO, CARDIO, "CLASSES", 10, 5, 5));
        dias.add(especialidad(MARTES, CARDIO, "CLASSES", 30, 20, 2, 3));
        dias.add(especialidad(MARTES, null, "CLASSES", 40, 15, 15, 8));
        var resultado = estimador.estimar(dias, List.of());
        var especialidad = unica(resultado, null, CARDIO);
        assertEquals(SPECIALTY, especialidad.fuenteVigente());
        assertEquals(especialidad.asistenciaPropia(), especialidad.asistenciaVigente(), EPS);
        var medico = unica(resultado, MEDICO, CARDIO);
        assertEquals(SPECIALTY, medico.fuenteVigente());
        assertEquals(especialidad.asistenciaPropia(), medico.asistenciaVigente(), EPS);
        assertEquals(especialidad.alfa(), medico.alfaVigente(), EPS, "La beta-binomial de O-04 usa α y β del nivel elegido");
        assertEquals(especialidad.beta(), medico.betaVigente(), EPS);

        // Sin especialidad suficiente se usa el área.
        dias.set(1, especialidad(MARTES, CARDIO, "CLASSES", 30, 10, 2, 3));
        resultado = estimador.estimar(dias, List.of());
        var area = unica(resultado, null, null);
        assertEquals(AREA, unica(resultado, MEDICO, CARDIO).fuenteVigente());
        assertEquals(area.asistenciaPropia(), unica(resultado, MEDICO, CARDIO).asistenciaVigente(), EPS);
        assertEquals(AREA, unica(resultado, null, CARDIO).fuenteVigente());
        assertEquals(AREA, area.fuenteVigente());

        // Si ningún nivel llega a 20, se usa la propia, que todavía pesa sobre todo el valor inicial.
        dias.set(2, especialidad(MARTES, null, "CLASSES", 40, 5, 5, 8));
        var propio = unica(estimador.estimar(dias, List.of()), MEDICO, CARDIO);
        assertEquals(INITIAL_VALUE, propio.fuenteVigente());
        assertEquals(propio.asistenciaPropia(), propio.asistenciaVigente(), EPS);
    }

    @Test
    void aDoctorWithTwentyObservedUsesTheirOwnEstimate() {
        var dias = List.of(medico(MARTES, MEDICO, CARDIO, "CLASSES", 20, 12, 8), especialidad(MARTES, CARDIO, "CLASSES", 40, 30, 2, 0));
        var medico = unica(estimador.estimar(dias, List.of()), MEDICO, CARDIO);
        assertEquals(DOCTOR, medico.fuenteVigente());
        assertEquals((0.95 * 8 + 12) / (0.95 * 8 + 12 + 0.95 * 2 + 8), medico.asistenciaVigente(), EPS);
    }

    @Test
    void noObservationsMeansNoEstimates() {
        assertTrue(estimador.estimar(List.of(), List.of(new ValorInicial(CARDIO, "CLASSES", 5.0, 0.8, 10))).isEmpty());
    }

    private static Observacion medico(LocalDate fecha, UUID personal, UUID especialidad, String tipo, int capacidad, int asistencias, int ausencias) {
        return new Observacion(fecha, personal, especialidad, tipo, capacidad, asistencias, ausencias, null);
    }

    private static Observacion especialidad(LocalDate fecha, UUID especialidad, String tipo, int capacidad, int asistencias, int ausencias, int solicitudes) {
        return new Observacion(fecha, null, especialidad, tipo, capacidad, asistencias, ausencias, solicitudes);
    }

    private static Estimacion unica(List<Estimacion> resultado, UUID personal, UUID especialidad) {
        return unica(resultado, personal, especialidad, "CLASSES");
    }

    private static Estimacion unica(List<Estimacion> resultado, UUID personal, UUID especialidad, String tipo) {
        var filas = resultado.stream().filter(e -> java.util.Objects.equals(e.idPersonal(), personal)
            && java.util.Objects.equals(e.idEspecialidad(), especialidad) && java.util.Objects.equals(e.tipoPeriodo(), tipo)).toList();
        assertEquals(1, filas.size(), "Una fila por clave");
        return filas.getFirst();
    }
}

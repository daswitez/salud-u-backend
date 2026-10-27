package bo.edu.uagrm.saludu.scheduling.application;

import static bo.edu.uagrm.saludu.scheduling.application.SugeridorAgenda.*;
import static org.junit.jupiter.api.Assertions.*;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class SugeridorAgendaTest {
    private static final UUID MEDICO = UUID.randomUUID(), CARDIO = UUID.randomUUID();
    private static final LocalDate DIA = LocalDate.parse("2027-03-02");
    private final SugeridorAgenda sugeridor = new SugeridorAgenda();

    @Test
    void saturationRiskIsTheBetaBinomialTail() {
        // Con Beta(1, 1) cada valor de 0 a N tiene probabilidad 1/(N + 1).
        assertEquals(1.0 / 12, riesgoSaturacion(11, 10, 1, 1), 1e-12);
        assertEquals(3.0 / 12, riesgoSaturacion(11, 8, 1, 1), 1e-12);
        // La probabilidad total es 1, y sin sobrecupo no hay riesgo.
        assertEquals(1, riesgoSaturacion(15, -1, 6, 4), 1e-12);
        assertEquals(0, riesgoSaturacion(10, 10, 6, 4));
        // P(X = 11) con Beta(6, 4) es 6·7·…·16 / (10·11·…·20) = 3024 / 116280.
        assertEquals(3024.0 / 116280, riesgoSaturacion(11, 10, 6, 4), 1e-12);
        // Con mucha evidencia se acerca a la binomial: 0,8^11.
        assertEquals(Math.pow(0.8, 11), riesgoSaturacion(11, 10, 800_000, 200_000), 1e-4);
    }

    @Test
    void suggestedAppointmentsRespectTheTenPercentLimitAndTheMaximumRisk() {
        assertEquals(9, citasSugeridas(9, 6, 4), "⌊9 × 1,10⌋ = 9: sin sobrecupo");
        assertEquals(11, citasSugeridas(10, 6, 4));
        assertEquals(10, citasSugeridas(10, 95, 5), "Con asistencia del 95 % una cita más satura demasiado");
        for (int c = 1; c <= 20; c++) {
            for (double[] ab : new double[][] { {6, 4}, {8, 2}, {3, 7}, {50, 10} }) {
                int n = citasSugeridas(c, ab[0], ab[1]), limite = c * 110 / 100;
                assertTrue(n >= c && n <= limite);
                assertTrue(riesgoSaturacion(n, c, ab[0], ab[1]) <= RIESGO_MAXIMO);
                assertTrue(n == limite || riesgoSaturacion(n + 1, c, ab[0], ab[1]) > RIESGO_MAXIMO);
            }
        }
    }

    @Test
    void overbookingRaisesTheLatestSlotsAndExplainsTheRule() {
        var resultado = sugeridor.jornada(jornada(cupos(10, 1), 6, 4, "SPECIALTY"));
        assertEquals(List.of(DAY_SLOTS, OVERBOOKING), resultado.stream().map(Sugerencia::tipo).toList());
        var cupos = jornada(cupos(10, 1), 6, 4, "SPECIALTY").cupos();
        var sobrecupo = resultado.get(1);
        assertEquals(1, sobrecupo.valor().get("sobrecupo"));
        @SuppressWarnings("unchecked") var elegidos = (List<Map<String, Object>>) sobrecupo.valor().get("cupos");
        assertEquals(1, elegidos.size());
        assertEquals(cupos.getLast().id().toString(), elegidos.getFirst().get("id_cupo"), "El último cupo de la jornada");
        assertEquals(2, elegidos.getFirst().get("capacidad_sugerida"));
        assertEquals(cupos.getFirst().iniciaA(), sobrecupo.venceEn(), "Vence cuando empieza la jornada");
        assertTrue(sobrecupo.explicacion().contains("agendar 1 cita más"), sobrecupo.explicacion());
        assertTrue(sobrecupo.explicacion().contains("asistencia estimada del 60 % (estimación de la especialidad)"), sobrecupo.explicacion());
        assertTrue(resultado.get(0).explicacion().contains("sobrecupo de 1 cita (RN-35"), resultado.get(0).explicacion());
        assertEquals(11, resultado.get(0).valor().get("citas_sugeridas"));
    }

    @Test
    void withoutOverbookingTheDaySuggestionSaysWhy() {
        var pequena = sugeridor.jornada(jornada(cupos(5, 1), 6, 4, "DOCTOR"));
        assertEquals(1, pequena.size());
        assertTrue(pequena.get(0).explicacion().contains("El límite del 10 % no admite citas extra"), pequena.get(0).explicacion());

        var llena = sugeridor.jornada(jornada(cupos(1, 20), 6, 4, "DOCTOR"));
        assertEquals(1, llena.size());
        assertEquals(20, llena.get(0).valor().get("citas_sugeridas"));
        assertTrue(llena.get(0).explicacion().contains("capacidad máxima de 20"), llena.get(0).explicacion());

        var asistida = sugeridor.jornada(jornada(cupos(10, 1), 95, 5, "AREA"));
        assertEquals(1, asistida.size());
        assertTrue(asistida.get(0).explicacion().contains("Una cita más superaría el riesgo máximo"), asistida.get(0).explicacion());
        assertTrue(asistida.get(0).explicacion().contains("estimación del área"));

        var decidida = new Jornada(DIA, MEDICO, CARDIO, cupos(10, 1).getFirst().iniciaA(), cupos(10, 1), 6, 4, "DOCTOR", true);
        assertTrue(sugeridor.jornada(decidida).isEmpty(), "Un sobrecupo ya decidido no se vuelve a calcular");
    }

    @Test
    void capacityAlertsFireAboveOneHundredAndBelowFiftyPercent() {
        LocalDate desde = LocalDate.parse("2027-03-01"), hasta = ultimoDiaHabil(desde, 10);
        assertEquals(LocalDate.parse("2027-03-12"), hasta);
        assertEquals(LocalDate.parse("2027-03-19"), ultimoDiaHabil(LocalDate.parse("2027-03-06"), 10), "Desde un sábado");

        var exceso = sugeridor.alerta(demanda(5, 20, 16, 0), desde, hasta).orElseThrow();
        assertEquals(CAPACITY_ALERT, exceso.tipo());
        assertEquals(true, exceso.valor().get("exceso_demanda"));
        assertEquals("105.0", exceso.valor().get("porcentaje").toString());
        assertTrue(exceso.explicacion().contains("el 105 %. Conviene solicitar una jornada adicional."), exceso.explicacion());
        assertEquals(desde, exceso.fecha());
        assertEquals(OffsetDateTime.parse("2027-03-02T00:00-04:00"), exceso.venceEn());

        assertTrue(sugeridor.alerta(demanda(5, 20, 15, 0), desde, hasta).isEmpty(), "100 % no alerta");
        assertTrue(sugeridor.alerta(demanda(0, 20, 10, 0), desde, hasta).isEmpty(), "50 % no alerta");
        var defecto = sugeridor.alerta(demanda(0, 20, 9.8, 3), desde, hasta).orElseThrow();
        assertEquals(false, defecto.valor().get("exceso_demanda"));
        assertTrue(defecto.explicacion().contains("el 49 %, menos de la mitad"), defecto.explicacion());
        assertTrue(defecto.explicacion().contains("En 3 días se usó la capacidad publicada"), defecto.explicacion());

        var sinOferta = sugeridor.alerta(demanda(3, 0, 0, 0), desde, hasta).orElseThrow();
        assertNull(sinOferta.valor().get("porcentaje"));
        assertTrue(sinOferta.explicacion().contains("no hay lugares libres publicados"));
        assertTrue(sugeridor.alerta(demanda(0, 0, 0, 0), desde, hasta).isEmpty());
    }

    private static DemandaEspecialidad demanda(int pendientes, int libres, double estimada, int sinEstimacion) {
        return new DemandaEspecialidad(CARDIO, pendientes, libres + 4, libres, estimada, 10, sinEstimacion);
    }

    private static Jornada jornada(List<Cupo> cupos, double alfa, double beta, String fuente) {
        return new Jornada(DIA, MEDICO, CARDIO, cupos.getFirst().iniciaA(), cupos, alfa, beta, fuente, false);
    }

    private static final Map<String, List<Cupo>> CUPOS = new java.util.HashMap<>();

    /** Cupos de 30 minutos desde las 08:00, siempre los mismos para una misma forma. */
    private static List<Cupo> cupos(int cantidad, int capacidad) {
        return CUPOS.computeIfAbsent(cantidad + "x" + capacidad, ignored -> {
            List<Cupo> lista = new ArrayList<>();
            for (int i = 0; i < cantidad; i++)
                lista.add(new Cupo(UUID.randomUUID(), OffsetDateTime.parse("2027-03-02T08:00:00-04:00").plusMinutes(30L * i), capacidad, 0));
            return List.copyOf(lista);
        });
    }
}

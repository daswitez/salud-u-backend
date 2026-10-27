package bo.edu.uagrm.saludu.scheduling.application;

import static bo.edu.uagrm.saludu.scheduling.application.SugeridorCupoSolicitud.*;
import static org.junit.jupiter.api.Assertions.*;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class SugeridorCupoSolicitudTest {
    private static final LocalDate HOY = LocalDate.parse("2027-03-01");
    private final SugeridorCupoSolicitud sugeridor = new SugeridorCupoSolicitud();
    // Mañana en una jornada casi llena (3 de 4) y en 10 días en una jornada vacía, ambas con 80 % de asistencia.
    private final Candidato pronto = candidato("2027-03-02T08:00:00-04:00", 4, 3, 0.8, "Dra. Rivas");
    private final Candidato tarde = candidato("2027-03-11T08:00:00-04:00", 4, 0, 0.8, "Dr. Paz");

    @Test
    void routineFavoursTheEmptierDayWhileUrgentFavoursTheSoonestOne() {
        // Rutina: mañana 100·(1 − (0,5·1/30 + 0,5·0,8)) = 58,3; en 10 días 100·(1 − (0,5·10/30 + 0,5·0,2)) = 73,3.
        var rutina = sugeridor.ordenar(List.of(pronto, tarde), "ROUTINE", HOY);
        assertEquals(List.of(tarde, pronto), rutina.stream().map(CupoSugerido::cupo).toList());
        assertEquals(73.3, rutina.get(0).puntaje());
        assertEquals(58.3, rutina.get(1).puntaje());
        assertEquals(0.2, rutina.get(0).ocupacionEsperada());
        assertEquals(10, rutina.get(0).diasEspera());
        // Urgente: mañana 100·(1 − (0,9/30 + 0,1·0,8)) = 89; en 10 días 100·(1 − (0,3 + 0,02)) = 68.
        var urgente = sugeridor.ordenar(List.of(pronto, tarde), "URGENT", HOY);
        assertEquals(List.of(pronto, tarde), urgente.stream().map(CupoSugerido::cupo).toList());
        assertEquals(89.0, urgente.get(0).puntaje());
        assertEquals(68.0, urgente.get(1).puntaje());
        assertEquals(List.of(1, 2), urgente.stream().map(CupoSugerido::orden).toList());
    }

    @Test
    void weightsDependOnPriorityAndNonReferralsCountAsRoutine() {
        assertEquals(0.9, pesoEspera("URGENT"));
        assertEquals(0.7, pesoEspera("PRIORITY"));
        assertEquals(0.5, pesoEspera("ROUTINE"));
        assertEquals(0.5, pesoEspera(null));
    }

    @Test
    void returnsTheBestThreeWithTiesBrokenByTheEarliestStart() {
        var a = candidato("2027-03-05T10:00:00-04:00", 4, 0, 0.8, "A");
        var b = candidato("2027-03-05T08:00:00-04:00", 4, 0, 0.8, "B");
        var c = candidato("2027-03-05T09:00:00-04:00", 4, 0, 0.8, "C");
        var d = candidato("2027-03-25T09:00:00-04:00", 4, 0, 0.8, "D");
        var resultado = sugeridor.ordenar(List.of(d, a, b, c), null, HOY);
        assertEquals(List.of(b, c, a), resultado.stream().map(CupoSugerido::cupo).toList());
        assertTrue(sugeridor.ordenar(List.of(), "URGENT", HOY).isEmpty());
    }

    @Test
    void waitAndOccupancyAreCappedAndTheExplanationGivesTheNumbers() {
        var lejano = candidato("2027-06-01T08:00:00-04:00", 2, 2, 1.0, "Dra. Lejos");
        var unico = sugeridor.ordenar(List.of(lejano), "PRIORITY", HOY).getFirst();
        assertEquals(0.0, unico.puntaje(), "Espera y ocupación topadas en 1");
        assertEquals(1.0, unico.ocupacionEsperada());

        var explicacion = sugeridor.ordenar(List.of(pronto), "URGENT", HOY).getFirst().explicacion();
        assertTrue(explicacion.startsWith("Martes 02/03 a las 08:00 con Dra. Rivas (en 1 día)."), explicacion);
        assertTrue(explicacion.contains("4 de 4 lugares ocupados"), explicacion);
        assertTrue(explicacion.contains("asistencia estimada del 80 % (valor inicial)"), explicacion);
        assertTrue(explicacion.contains("ocupación esperada del 80 %"), explicacion);
        assertTrue(explicacion.contains("Derivación urgente: la espera pesa el 90 % y la ocupación el 10 %. Puntaje 89."), explicacion);
        assertTrue(sugeridor.ordenar(List.of(candidato("2027-03-01T15:00:00-04:00", 4, 0, 0.8, "Hoy")), null, HOY)
            .getFirst().explicacion().contains("(hoy). "));
    }

    private static Candidato candidato(String inicio, int capacidadJornada, int ocupadosJornada, double asistencia, String medico) {
        OffsetDateTime inicia = OffsetDateTime.parse(inicio);
        return new Candidato(UUID.randomUUID(), inicia, inicia.plusMinutes(30), UUID.randomUUID(), medico, UUID.randomUUID(), "Cardiología",
            1, capacidadJornada, ocupadosJornada, asistencia, "INITIAL_VALUE");
    }
}

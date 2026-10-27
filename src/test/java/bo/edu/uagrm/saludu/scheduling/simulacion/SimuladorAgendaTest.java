package bo.edu.uagrm.saludu.scheduling.simulacion;

import static org.junit.jupiter.api.Assertions.*;

import bo.edu.uagrm.saludu.scheduling.simulacion.SimuladorAgenda.Fila;
import bo.edu.uagrm.saludu.scheduling.simulacion.SimuladorAgenda.Parametros;
import bo.edu.uagrm.saludu.scheduling.simulacion.SimuladorAgenda.Tramo;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class SimuladorAgendaTest {
    private static final LocalDate INICIO = LocalDate.parse("2027-02-01");
    private final SimuladorAgenda simulador = new SimuladorAgenda();

    @Test
    void theSameSeedRepeatsTheRunAndBothPoliciesReceiveTheSameRequests() {
        var tramos = List.of(tramo("CLASSES", "NORMAL", 4, 12, 0.8, 0.8));
        List<Fila> una = simulador.simular(tramos, parametros(7, 3, 1.0)), otra = simulador.simular(tramos, parametros(7, 3, 1.0));
        assertEquals(una, otra);
        assertNotEquals(una, simulador.simular(tramos, parametros(8, 3, 1.0)));
        for (int replica = 1; replica <= 3; replica++) {
            int r = replica;
            var deLaReplica = una.stream().filter(f -> f.replica() == r).toList();
            assertEquals(2, deLaReplica.size());
            assertEquals(deLaReplica.get(0).solicitudes(), deLaReplica.get(1).solicitudes(), "Números aleatorios comunes");
        }
    }

    @Test
    void rejectingEverySuggestionReproducesTheFixedAgendaExactly() {
        var tramos = List.of(tramo("SEMESTER_START", "ALTA", 3, 20, 0.8, 0.7), tramo("VACATIONS", "BAJA", 3, 4, 0.8, 0.7));
        for (Fila f : simulador.simular(tramos, parametros(11, 2, 0.0))) {
            if (!SimuladorAgenda.CON_SUGERENCIAS.equals(f.politica())) continue;
            Fila fija = simulador.simular(tramos, parametros(11, 2, 0.0)).stream().filter(x -> x.replica() == f.replica()
                && x.desde().equals(f.desde()) && SimuladorAgenda.AGENDA_FIJA.equals(x.politica())).findFirst().orElseThrow();
            assertEquals(0, f.sugerenciasAceptadas());
            assertTrue(f.sugerenciasEmitidas() > 0, "Igual se emiten y se registran");
            assertEquals(fija, new Fila(f.replica(), f.especialidad(), f.tipoPeriodo(), f.temporada(), f.desde(), f.hasta(),
                SimuladorAgenda.AGENDA_FIJA, f.solicitudes(), f.jornadas(), f.lugaresPublicados(), f.lugaresOciosos(), f.tasaOciosos(),
                f.solicitudesAsignadas(), f.esperaPromedio(), f.esperaMediana(), f.esperaP90(), f.jornadasSobrecargadas(), f.tasaSobrecarga(),
                f.sobrecupoMaximo(), f.citasEvaluadas(), f.brier(), f.brierBase(), f.diasDemanda(), f.errorDemanda(), f.errorDemandaBase(),
                0, 0, 0, 0, f.pendientesAlFinal()));
        }
    }

    @Test
    void inHighSeasonExtraDaysShortenTheWaitAndInLowSeasonReleasedDaysReduceIdlePlaces() {
        // Demanda de 3 con 16 lugares por día: sobran lugares. Demanda de 22: la agenda fija acumula espera. La
        // temporada baja va primero para que no arrastre el atraso de la alta.
        var tramos = List.of(tramo("VACATIONS", "BAJA", 4, 3, 0.8, 0.8), tramo("SEMESTER_START", "ALTA", 4, 22, 0.8, 0.8));
        List<Fila> filas = simulador.simular(tramos, parametros(3, 10, 1.0));
        var resumen = InformeSimulacion.resumir(filas);
        var alta = resumen.stream().filter(r -> "ALTA".equals(r.ejemplo().temporada()) && r.espera() != null).findFirst().orElseThrow();
        var baja = resumen.stream().filter(r -> "BAJA".equals(r.ejemplo().temporada()) && r.ociosos() != null).findFirst().orElseThrow();
        assertTrue(alta.espera().superior() < 0, "Menos espera: " + alta.espera());
        assertTrue(baja.ociosos().superior() < 0, "Menos cupos ociosos: " + baja.ociosos());
        assertEquals("SI", alta.cumple());
        assertEquals("SI", baja.cumple());
        assertTrue(filas.stream().filter(f -> "ALTA".equals(f.temporada()) && SimuladorAgenda.CON_SUGERENCIAS.equals(f.politica()))
            .allMatch(f -> f.jornadasAdicionales() > 0));
        assertTrue(filas.stream().filter(f -> "BAJA".equals(f.temporada()) && SimuladorAgenda.CON_SUGERENCIAS.equals(f.politica()))
            .allMatch(f -> f.jornadasLiberadas() > 0));
    }

    @Test
    void overbookingNeverExceedsRn35AndTheModelLearnsWhenTheReportedAttendanceIsWrong() {
        // El personal informó 0,9 pero llegan 6 de cada 10. Con 12 lugares RN-35 admite hasta 13 (⌊13,2⌋); con 8, ninguno.
        var tramos = List.of(tramo("CLASSES", "NORMAL", 6, 24, 0.9, 0.6, 12), tramo("EXAMS", "NORMAL", 6, 24, 0.9, 0.6, 12));
        List<Fila> filas = simulador.simular(tramos, parametros(5, 3, 1.0));
        for (Fila f : filas) {
            assertTrue(f.sobrecupoMaximo() <= 0.10 + 1e-9, "RN-35: " + f.sobrecupoMaximo());
            assertTrue(f.lugaresOciosos() <= f.lugaresPublicados());
        }
        var conSugerencias = filas.stream().filter(f -> SimuladorAgenda.CON_SUGERENCIAS.equals(f.politica())).toList();
        assertTrue(conSugerencias.stream().anyMatch(f -> f.sobrecupoMaximo() > 0), "Con 60 % de asistencia hay sobrecupo");
        assertTrue(simulador.simular(List.of(tramo("CLASSES", "NORMAL", 6, 16, 0.9, 0.6)), parametros(5, 2, 1.0)).stream()
            .allMatch(f -> f.sobrecupoMaximo() == 0), "Con 8 lugares por jornada RN-35 no deja sobrecupo");
        assertTrue(conSugerencias.stream().filter(f -> "EXAMS".equals(f.tipoPeriodo())).allMatch(f -> f.brier() < f.brierBase()),
            "El modelo calibra mejor que repetir 0,9");
    }

    @Test
    void poissonAndPercentilesFollowTheirDefinitions() {
        Random azar = new Random(1);
        double suma = 0;
        for (int i = 0; i < 20000; i++) suma += SimuladorAgenda.poisson(azar, 6.5);
        assertEquals(6.5, suma / 20000, 0.1);
        assertEquals(3.8, SimuladorAgenda.percentil(List.of(2.0, 4.0), 0.9), 1e-9);
        assertEquals(3.0, SimuladorAgenda.percentil(List.of(2.0, 4.0), 0.5), 1e-9);
        assertNull(SimuladorAgenda.percentil(List.of(), 0.5));
        assertEquals(2.093, InformeSimulacion.cuantilT(19));
        assertEquals(1.96, InformeSimulacion.cuantilT(40));
    }

    @Test
    void theCsvFilesSayItIsASimulationAndCarryEverythingNeededToRepeatIt(@TempDir Path carpeta) throws Exception {
        var tramos = InformeSimulacion.leerEscenarios(getClass().getResourceAsStream("/simulacion/escenarios.csv"));
        assertEquals(8, tramos.size());
        assertEquals(new Tramo("Psicología", 1, 10, "EXAMS", "ALTA", 3, 13, 0.85, 10, 0.80), tramos.get(6));
        List<Fila> filas = simulador.simular(tramos, parametros(9, 2, 1.0));
        assertEquals(2 * 8 * 2, filas.size());
        var archivos = InformeSimulacion.escribir(filas, parametros(9, 2, 1.0), OffsetDateTime.parse("2026-10-27T10:00:00-04:00"), carpeta);
        assertEquals("simulacion-o09-detalle-20261027T1000.csv", archivos.detalle().getFileName().toString());
        List<String> detalle = Files.readAllLines(archivos.detalle()), resumen = Files.readAllLines(archivos.resumen());
        assertTrue(detalle.getFirst().startsWith("origen,fecha_ejecucion,version_simulador,version_estimador,version_sugeridor,semilla,replicas,parametros,replica,"));
        assertEquals(1 + filas.size(), detalle.size());
        assertEquals(1 + 8 * 2, resumen.size());
        for (String linea : new ArrayList<>(detalle.subList(1, detalle.size()))) {
            assertTrue(linea.startsWith("SIMULACION,2026-10-27T10:00-04:00,o09-v1,o03-v1,o04-v1,9,2,\"aceptacion=1.00;horizonte_dias_habiles=10;"), linea);
        }
        assertTrue(resumen.stream().anyMatch(l -> l.contains("Temporada alta: espera menor")));
        int columnas = resumen.getFirst().split(",").length;
        assertTrue(resumen.stream().skip(1).allMatch(l -> l.contains("SIMULACION")) && columnas == 34, "columnas " + columnas);
    }

    private static Tramo tramo(String tipo, String temporada, int semanas, double demanda, double esperada, double real) {
        return tramo(tipo, temporada, semanas, demanda, esperada, real, 8);
    }

    private static Tramo tramo(String tipo, String temporada, int semanas, double demanda, double esperada, double real, int capacidad) {
        return new Tramo("Prueba", 2, capacidad, tipo, temporada, semanas, demanda, esperada, 10, real);
    }

    private static Parametros parametros(long semilla, int replicas, double aceptacion) {
        return new Parametros(semilla, replicas, aceptacion, 10, 2, 2, INICIO);
    }
}

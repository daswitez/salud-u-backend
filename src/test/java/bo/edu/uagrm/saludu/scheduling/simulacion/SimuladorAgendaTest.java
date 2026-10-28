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
                f.diasSaturados(), f.solicitudesAsignadas(), f.esperaPromedio(), f.esperaMediana(), f.esperaP90(), f.jornadasSobrecargadas(), f.tasaSobrecarga(),
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
        assertTrue(Double.parseDouble(InformeSimulacion.texto(-0.00000000001)) < 0, "El IC no debe redondear diferencias negativas a cero");
    }

    @Test
    void theCsvFilesSayItIsASimulationAndCarryEverythingNeededToRepeatIt(@TempDir Path carpeta) throws Exception {
        var tramos = InformeSimulacion.leerEscenarios(getClass().getResourceAsStream("/simulacion/escenarios.csv"));
        assertEquals(30, tramos.size());
        assertEquals("Revisión médica", tramos.getFirst().especialidad());
        List<Fila> filas = simulador.simular(tramos, parametros(9, 2, 1.0));
        assertEquals(2 * 30 * 2, filas.size());
        var altaJunio = filas.stream().filter(f -> f.replica() == 1 && f.especialidad().equals("Revisión médica") && f.tipoPeriodo().equals("CLASSES") && f.temporada().equals("ALTA")).findFirst().orElseThrow();
        var altaJulio = filas.stream().filter(f -> f.replica() == 1 && f.especialidad().equals("Revisión médica") && f.tipoPeriodo().equals("EXAMS")).findFirst().orElseThrow();
        assertEquals(LocalDate.parse("2027-05-31"), altaJunio.desde());
        assertEquals(LocalDate.parse("2027-07-02"), altaJunio.hasta());
        assertEquals(LocalDate.parse("2027-07-05"), altaJulio.desde());
        assertEquals(LocalDate.parse("2027-07-30"), altaJulio.hasta());
        var archivos = InformeSimulacion.escribir(filas, parametros(9, 2, 1.0), OffsetDateTime.parse("2026-10-27T10:00:00-04:00"), carpeta);
        assertEquals("simulacion-o09-detalle-20261027T1000.csv", archivos.detalle().getFileName().toString());
        List<String> detalle = Files.readAllLines(archivos.detalle()), resumen = Files.readAllLines(archivos.resumen());
        assertTrue(detalle.getFirst().startsWith("origen,fecha_ejecucion,version_simulador,version_estimador,version_sugeridor,semilla,replicas,parametros,replica,"));
        assertEquals(1 + filas.size(), detalle.size());
        assertEquals(1 + 30 * 2, resumen.size());
        assertEquals(1 + 30 * 2 * 6, Files.readAllLines(archivos.indicadores()).size());
        for (String linea : new ArrayList<>(detalle.subList(1, detalle.size()))) {
            assertTrue(linea.startsWith("SIMULACION,2026-10-27T10:00-04:00,o09-v2,o03-v1,o04-v1,9,2,\"aceptacion=1.00;horizonte_dias_habiles=10;"), linea);
        }
        assertTrue(resumen.stream().anyMatch(l -> l.contains("Temporada alta: espera menor")));
        int columnas = resumen.getFirst().split(",").length;
        assertTrue(resumen.stream().skip(1).allMatch(l -> l.contains("SIMULACION")) && columnas == 35, "columnas " + columnas);
    }

    @Test
    void weeklyProfilePreservesLegacyDefaultAndPairedRequestsAndChangesDemand() throws Exception {
        var original = new Tramo("Perfil", 2, 8, "CLASSES", "NORMAL", 8, 12, 0.8, 10, 0.8);
        var explicito = new Tramo("Perfil", 2, 8, "CLASSES", "NORMAL", 8, 12, 0.8, 10, 0.8, List.of(1.0, 1.0, 1.0, 1.0, 1.0));
        var perfil = new Tramo("Perfil", 2, 8, "CLASSES", "NORMAL", 8, 12, 0.8, 10, 0.8, List.of(3.0, 0.0, 0.0, 0.0, 0.0));
        assertEquals(36.0, perfil.demandaEn(java.time.DayOfWeek.MONDAY));
        assertEquals(0.0, perfil.demandaEn(java.time.DayOfWeek.FRIDAY));
        assertEquals(simulador.simular(List.of(original), parametros(13, 3, 1)), simulador.simular(List.of(explicito), parametros(13, 3, 1)));
        var filas = simulador.simular(List.of(perfil), parametros(13, 3, 1));
        assertNotEquals(simulador.simular(List.of(original), parametros(13, 3, 1)), filas);
        for (int n = 1; n <= 3; n++) {
            int replica = n;
            var pareja = filas.stream().filter(f -> f.replica() == replica).toList();
            assertEquals(pareja.get(0).solicitudes(), pareja.get(1).solicitudes());
            assertTrue(pareja.get(0).diasSaturados() > 0);
            assertTrue(pareja.stream().allMatch(f -> f.diasSaturados() <= 8), "Solo el lunes recibe solicitudes");
        }
        assertThrows(IllegalArgumentException.class, () -> new Tramo("Perfil", 1, 8, "CLASSES", "NORMAL", 1, 3, .8, 10, .8, List.of(1.0, -1.0)));
        String old = "especialidad,medicos,capacidad_jornada,tipo_periodo,temporada,semanas,demanda_diaria,asistencia_esperada,peso_citas,asistencia_real\nPerfil,2,8,CLASSES,NORMAL,8,12,0.8,10,0.8\n";
        var parsed = InformeSimulacion.leerEscenarios(new java.io.ByteArrayInputStream(old.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        assertEquals(original, parsed.getFirst());
        var sinLlegadas = new Tramo("Vacío", 1, 5, "CLASSES", "NORMAL", 2, 3, .8, 10, .8, List.of(0.0, 0.0, 0.0, 0.0, 0.0));
        assertDoesNotThrow(() -> InformeSimulacion.resumir(simulador.simular(List.of(sinLlegadas), parametros(13, 2, 1))));
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

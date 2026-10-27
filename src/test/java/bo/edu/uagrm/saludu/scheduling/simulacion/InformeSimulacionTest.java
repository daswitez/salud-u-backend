package bo.edu.uagrm.saludu.scheduling.simulacion;

import static org.junit.jupiter.api.Assertions.*;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;

/**
 * O-09: genera los CSV del Apéndice A.6 en cada {@code mvn verify}. Para otra corrida:
 * {@code mvn -o test -Dtest=InformeSimulacionTest -Dsimulacion.escenarios=ruta.csv -Dsimulacion.replicas=50
 * -Dsimulacion.semilla=1 -Dsimulacion.aceptacion=0.8 -Dsimulacion.salida=docs/evaluacion}.
 */
class InformeSimulacionTest {
    @Test
    void writesTheSimulationReport() throws Exception {
        var defecto = SimuladorAgenda.Parametros.porDefecto();
        var parametros = new SimuladorAgenda.Parametros(Long.getLong("simulacion.semilla", defecto.semilla()),
            Integer.getInteger("simulacion.replicas", defecto.replicas()),
            Double.parseDouble(System.getProperty("simulacion.aceptacion", String.valueOf(defecto.aceptacion()))),
            defecto.horizonte(), defecto.semanasCalentamiento(), defecto.jornadasAdicionalesSemanales(), defecto.inicio());
        String ruta = System.getProperty("simulacion.escenarios");
        try (InputStream escenarios = ruta == null ? getClass().getResourceAsStream("/simulacion/escenarios.csv") : Files.newInputStream(Path.of(ruta))) {
            var tramos = InformeSimulacion.leerEscenarios(escenarios);
            var filas = new SimuladorAgenda().simular(tramos, parametros);
            var archivos = InformeSimulacion.escribir(filas, parametros, InformeSimulacion.ahora(),
                Path.of(System.getProperty("simulacion.salida", "target/simulacion")));
            assertEquals(1 + filas.size(), Files.readAllLines(archivos.detalle()).size());
            System.out.println("Simulación O-09: " + archivos.detalle() + " y " + archivos.resumen());
        }
    }
}

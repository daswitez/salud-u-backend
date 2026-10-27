package bo.edu.uagrm.saludu.scheduling.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

/** O-03: recalcula todas las estimaciones desde las observaciones con {@link EstimadorAgenda} y las reemplaza. */
@Service
public class ScheduleEstimationService {
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;
    private final EstimadorAgenda estimador = new EstimadorAgenda();

    public ScheduleEstimationService(JdbcTemplate jdbc, ObjectMapper json) { this.jdbc = jdbc; this.json = json; }

    @Transactional(isolation = Isolation.REPEATABLE_READ)
    public int recompute() {
        List<EstimadorAgenda.Observacion> observaciones = jdbc.query("select * from salud_u.observaciones_para_estimacion()",
            (rs, n) -> new EstimadorAgenda.Observacion(rs.getObject("fecha", LocalDate.class), rs.getObject("id_personal", UUID.class),
                rs.getObject("id_especialidad", UUID.class), rs.getString("tipo_periodo"), rs.getInt("capacidad"),
                rs.getInt("asistencias"), rs.getInt("ausencias"), rs.getObject("solicitudes_ingresadas", Integer.class)));
        List<EstimadorAgenda.ValorInicial> iniciales = jdbc.query("select * from salud_u.valores_iniciales_para_estimacion()",
            (rs, n) -> new EstimadorAgenda.ValorInicial(rs.getObject("id_especialidad", UUID.class), rs.getString("tipo_periodo"),
                rs.getBigDecimal("demanda_diaria_esperada") == null ? null : rs.getBigDecimal("demanda_diaria_esperada").doubleValue(),
                rs.getBigDecimal("asistencia_esperada").doubleValue(), rs.getInt("peso_citas")));
        ArrayNode filas = json.createArrayNode();
        for (EstimadorAgenda.Estimacion estimacion : estimador.estimar(observaciones, iniciales)) {
            ObjectNode fila = filas.addObject();
            fila.put("id_especialidad", estimacion.idEspecialidad() == null ? null : estimacion.idEspecialidad().toString());
            fila.put("id_personal", estimacion.idPersonal() == null ? null : estimacion.idPersonal().toString());
            fila.put("dia_semana", estimacion.diaSemana());
            fila.put("tipo_periodo", estimacion.tipoPeriodo());
            fila.put("alfa_asistencia", decimal(estimacion.alfa(), 6));
            fila.put("beta_asistencia", decimal(estimacion.beta(), 6));
            fila.put("demanda_suavizada", estimacion.demandaSuavizada() == null ? null : decimal(estimacion.demandaSuavizada(), 4));
            fila.put("citas_observadas", estimacion.citasObservadas());
            fila.put("jornadas_observadas", estimacion.jornadasObservadas());
            fila.put("ultima_fecha", estimacion.ultimaFecha().toString());
            fila.put("asistencia_vigente", decimal(estimacion.asistenciaVigente(), 3));
            fila.put("fuente_vigente", estimacion.fuenteVigente());
            fila.put("alfa_vigente", decimal(estimacion.alfaVigente(), 6));
            fila.put("beta_vigente", decimal(estimacion.betaVigente(), 6));
        }
        return jdbc.queryForObject("select salud_u.guardar_estimaciones_agenda(cast(? as jsonb), ?)", Integer.class,
            filas.toString(), EstimadorAgenda.VERSION_MODELO);
    }

    private static BigDecimal decimal(double value, int scale) { return BigDecimal.valueOf(value).setScale(scale, RoundingMode.HALF_UP); }
}

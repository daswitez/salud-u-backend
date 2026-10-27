package bo.edu.uagrm.saludu.scheduling.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

/** O-08: junta los indicadores contados en la base con la evaluación retrospectiva de {@link EvaluadorAgenda}. */
@Service
public class SchedulingMetricsService {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final ObjectMapper json;
    private final ScheduleEstimationService estimations;
    private final EvaluadorAgenda evaluador = new EvaluadorAgenda();

    public SchedulingMetricsService(JdbcTemplate jdbc, DatabaseActorContext actorContext, ObjectMapper json, ScheduleEstimationService estimations) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.json = json;
        this.estimations = estimations;
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public SchedulingMetrics metrics(SessionPrincipal principal, LocalDate from, LocalDate to) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        Map<String, Object> row;
        try {
            row = jdbc.queryForMap("select jornadas, lugares_publicados, lugares_ociosos, jornadas_sobrecargadas, jornadas_con_sobrecupo,"
                + " solicitudes_asignadas, espera_promedio_dias, espera_mediana_dias, espera_p90_dias, sugerencias::text as sugerencias,"
                + " avisos::text as avisos from salud_u.metricas_agenda(?, ?)", from, to);
        } catch (DataAccessException exception) {
            String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
            if (detail.contains("Se requiere el rol ADMINISTRATIVO")) throw new AvailabilityException(403, "Solo Administración puede ver las métricas de la agenda.");
            if (detail.contains("PERIODO_METRICAS_INVALIDO")) throw invalidPeriod();
            throw exception;
        }
        EvaluadorAgenda.Evaluacion evaluacion = evaluador.evaluar(estimations.observaciones(), estimations.valoresIniciales(), from, to);

        int days = number(row, "jornadas"), published = number(row, "lugares_publicados"), idle = number(row, "lugares_ociosos");
        int overloaded = number(row, "jornadas_sobrecargadas");
        List<SchedulingMetrics.SuggestionsByType> byType = new ArrayList<>();
        int issued = 0, accepted = 0, modified = 0, rejected = 0, expired = 0, pending = 0;
        for (JsonNode t : read((String) row.get("sugerencias"))) {
            var item = new SchedulingMetrics.SuggestionsByType(t.path("tipo").asText(), t.path("emitidas").asInt(), t.path("aceptadas").asInt(),
                t.path("modificadas").asInt(), t.path("rechazadas").asInt(), t.path("vencidas").asInt(), t.path("pendientes").asInt());
            byType.add(item);
            issued += item.issued(); accepted += item.accepted(); modified += item.modified();
            rejected += item.rejected(); expired += item.expired(); pending += item.pending();
        }
        List<SchedulingMetrics.NotificationsByType> notices = new ArrayList<>();
        int registered = 0, delivered = 0, readCount = 0;
        for (JsonNode a : read((String) row.get("avisos"))) {
            var item = new SchedulingMetrics.NotificationsByType(a.path("tipo").asText(), a.path("registrados").asInt(), a.path("entregados").asInt(), a.path("leidos").asInt());
            notices.add(item);
            registered += item.registered(); delivered += item.delivered(); readCount += item.read();
        }
        var calibracion = evaluacion.calibracion();
        var demanda = evaluacion.demanda();
        Double skill = calibracion.brier() == null || calibracion.brierBase() == null || calibracion.brierBase() == 0 ? null
            : round(1 - calibracion.brier() / calibracion.brierBase(), 4);
        return new SchedulingMetrics(from, to, EstimadorAgenda.VERSION_MODELO,
            new SchedulingMetrics.IdlePlaces(days, published, idle, ratio(idle, published)),
            new SchedulingMetrics.Wait(number(row, "solicitudes_asignadas"), decimal(row, "espera_promedio_dias"),
                decimal(row, "espera_mediana_dias"), decimal(row, "espera_p90_dias")),
            new SchedulingMetrics.Overload(days, overloaded, ratio(overloaded, days), SugeridorAgenda.RIESGO_MAXIMO, number(row, "jornadas_con_sobrecupo")),
            new SchedulingMetrics.AttendanceCalibration(calibracion.citas(), round(calibracion.brier(), 4), round(calibracion.brierBase(), 4), skill),
            new SchedulingMetrics.DemandError(demanda.dias(), round(demanda.errorMedio(), 3), demanda.diasComparables(),
                round(demanda.errorMedioComparable(), 3), round(demanda.errorMedioBase(), 3)),
            new SchedulingMetrics.Suggestions(issued, accepted, modified, rejected, expired, pending, ratio(accepted + modified, issued), byType),
            new SchedulingMetrics.Notifications(registered, delivered, readCount, ratio(readCount, delivered), notices));
    }

    public static AvailabilityException invalidPeriod() {
        return new AvailabilityException(400, "Indica un período de hasta 366 días con fechas AAAA-MM-DD, la inicial antes que la final.");
    }

    private JsonNode read(String value) {
        try { return json.readTree(value); }
        catch (JsonProcessingException exception) { throw new IllegalStateException("Métricas ilegibles.", exception); }
    }

    private static int number(Map<String, Object> row, String key) { return ((Number) row.get(key)).intValue(); }

    private static Double decimal(Map<String, Object> row, String key) {
        return row.get(key) == null ? null : ((BigDecimal) row.get(key)).doubleValue();
    }

    private static Double ratio(int part, int total) { return total == 0 ? null : round((double) part / total, 4); }

    private static Double round(Double value, int scale) {
        return value == null ? null : BigDecimal.valueOf(value).setScale(scale, RoundingMode.HALF_UP).doubleValue();
    }
}

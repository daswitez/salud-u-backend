package bo.edu.uagrm.saludu.reports.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/reports")
public class InstitutionalComplianceController {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;

    public InstitutionalComplianceController(JdbcTemplate jdbc, DatabaseActorContext actorContext) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
    }

    @GetMapping("/compliance")
    @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER')")
    @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<List<Map<String, Object>>> compliance(
        @RequestParam(required = false) UUID careerId,
        @RequestParam(required = false) String period,
        @AuthenticationPrincipal SessionPrincipal principal
    ) {
        if (period != null && (period.isBlank() || period.trim().length() > 80)) {
            throw new AvailabilityException(400, "El período académico no es válido.");
        }
        apply(principal);
        try {
            var rows = jdbc.query("select * from salud_u.reporte_cumplimiento_institucional(?, ?)", (rs, ignored) -> {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("patientId", rs.getObject("id_paciente", UUID.class));
                row.put("carnet", rs.getString("carnet"));
                row.put("fullName", rs.getString("nombre_completo"));
                row.put("careerId", rs.getObject("id_carrera", UUID.class));
                row.put("careerName", rs.getString("nombre_carrera"));
                row.put("academicPeriod", rs.getString("periodo_academico"));
                row.put("firstClosedEncounterAt", rs.getObject("primer_encuentro_cerrado_en"));
                row.put("complianceStatus", rs.getString("estado_cumplimiento"));
                return row;
            }, careerId, period == null ? null : period.trim());
            return LegacyAvailabilityResponse.success(rows);
        } catch (DataAccessException exception) {
            throw databaseError(exception, "No se pudo consultar el cumplimiento institucional.");
        }
    }

    @GetMapping("/daily-activity")
    @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER')")
    @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<List<Map<String, Object>>> dailyActivity(
        @RequestParam(required = false) LocalDate from,
        @RequestParam(required = false) LocalDate to,
        @AuthenticationPrincipal SessionPrincipal principal
    ) {
        LocalDate first = from == null ? LocalDate.now() : from;
        LocalDate last = to == null ? first : to;
        if (first.isAfter(last) || first.plusDays(366).isBefore(last)) {
            throw new AvailabilityException(400, "El período no es válido.");
        }
        apply(principal);
        try {
            return LegacyAvailabilityResponse.success(jdbc.query("select * from salud_u.actividad_diaria_atencion(?, ?)", (rs, ignored) -> {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("activityDay", rs.getObject("fecha_actividad", LocalDate.class));
                row.put("encounterType", rs.getString("tipo_encuentro"));
                row.put("specialtyName", rs.getString("nombre_especialidad"));
                row.put("totalClosed", rs.getLong("total_cerradas"));
                return row;
            }, first, last));
        } catch (DataAccessException exception) {
            throw databaseError(exception, "No se pudo consultar la actividad institucional.");
        }
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    private AvailabilityException databaseError(DataAccessException exception, String fallback) {
        String message = exception.getMostSpecificCause().getMessage();
        if (message != null && (message.contains("RANGO_FECHAS_INVALIDO") || message.contains("PERIODO_ACADEMICO_INVALIDO"))) {
            return new AvailabilityException(400, "El período no es válido.");
        }
        if (message != null && message.contains("Se requiere el rol")) {
            return new AvailabilityException(403, "No tienes permiso para consultar este reporte.");
        }
        return new AvailabilityException(400, fallback);
    }
}

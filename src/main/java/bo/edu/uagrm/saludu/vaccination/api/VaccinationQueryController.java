package bo.edu.uagrm.saludu.vaccination.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.ObjectMapper;
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
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class VaccinationQueryController {
    private final JdbcTemplate jdbc; private final DatabaseActorContext actorContext; private final ObjectMapper json;
    public VaccinationQueryController(JdbcTemplate jdbc, DatabaseActorContext actorContext, ObjectMapper json) { this.jdbc = jdbc; this.actorContext = actorContext; this.json = json; }

    @GetMapping("/api/vaccination-card") @PreAuthorize("hasAnyRole('ADMINISTRATIVE','STUDENT')") @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<Object> card(@RequestParam(required = false) UUID patientId, @AuthenticationPrincipal SessionPrincipal principal) {
        apply(principal);
        try { return LegacyAvailabilityResponse.success(json.readValue(jdbc.queryForObject("select salud_u.obtener_carnet_vacunacion(?)::text", String.class, patientId), Object.class)); }
        catch (DataAccessException exception) { throw cardException(exception); }
        catch (Exception exception) { throw new AvailabilityException(400, "No se pudo consultar el carnet de vacunación."); }
    }

    @GetMapping("/api/reports/vaccination-coverage") @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER')") @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<List<Map<String, Object>>> coverage(@RequestParam(required = false) UUID careerId, @RequestParam(required = false) String academicPeriod, @AuthenticationPrincipal SessionPrincipal principal) {
        if (academicPeriod != null && academicPeriod.trim().length() > 80) throw new AvailabilityException(400, "El período académico no es válido.");
        apply(principal);
        try { return LegacyAvailabilityResponse.success(jdbc.query("select * from salud_u.reporte_cobertura_vacunacion(?, ?)", (rs, ignored) -> { Map<String, Object> row = new LinkedHashMap<>(); row.put("vaccineId", rs.getObject("id_vacuna", UUID.class)); row.put("vaccineCode", rs.getString("codigo_vacuna")); row.put("vaccineName", rs.getString("nombre_vacuna")); row.put("careerId", rs.getObject("id_carrera", UUID.class)); row.put("careerName", rs.getString("nombre_carrera")); row.put("academicPeriod", rs.getString("periodo_academico")); row.put("totalStudents", rs.getLong("total_estudiantes")); row.put("completedSchedules", rs.getLong("esquemas_completos")); row.put("coveragePercentage", rs.getBigDecimal("porcentaje_cobertura")); return row; }, careerId, academicPeriod)); }
        catch (DataAccessException exception) { throw new AvailabilityException(400, "No se pudo consultar la cobertura de vacunación."); }
    }
    private void apply(SessionPrincipal principal) { actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles()))); }
    private AvailabilityException cardException(DataAccessException exception) { String message = String.valueOf(exception.getMostSpecificCause().getMessage()); if (message.contains("CARNET_VACUNACION_NO_AUTORIZADO")) return new AvailabilityException(403, "No tiene acceso a este carnet de vacunación."); if (message.contains("PACIENTE_NO_ENCONTRADO")) return new AvailabilityException(404, "El paciente no existe."); return new AvailabilityException(400, "No se pudo consultar el carnet de vacunación."); }
}

package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/medical/encounters")
public class MedicalEncounterController {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;
    private final ObjectMapper objectMapper;

    public MedicalEncounterController(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter, ObjectMapper objectMapper) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
        this.objectMapper = objectMapper;
    }

    @PostMapping("/{encounterId}/finalize")
    @PreAuthorize("hasRole('REVIEW_DOCTOR')")
    @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<UUID>> finalizeEncounter(
        @PathVariable UUID encounterId, @RequestBody Map<String, Object> body, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        String chiefComplaint = text(body.get("chiefComplaint"), 4000);
        String assessment = text(body.get("assessment"), 8000);
        String bloodStatus = text(body.get("bloodChemistryStatus"), 30);
        if (chiefComplaint == null || assessment == null || body.get("reviewHistory") == null) throw new AvailabilityException(400, "El motivo de consulta, la evaluación y la ficha de revisión son obligatorios.");
        apply(principal);
        try {
            UUID completed = jdbcTemplate.queryForObject(
                "select salud_u.finalizar_encuentro_revision(?, ?, ?, ?, ?, ?, ?, cast(? as jsonb))", UUID.class,
                encounterId, chiefComplaint, assessment, text(body.get("instructions"), 8000), text(body.get("followUpText"), 4000),
                bloodStatus == null ? "NOT_PRESENTED" : bloodStatus, text(body.get("diagnosisText"), 2000), objectMapper.writeValueAsString(body.get("reviewHistory"))
            );
            auditWriter.append("ENCUENTRO_REVISION_CERRADO", "encuentro_clinico", completed, AuditOutcome.SUCCESS, Map.of());
            return ResponseEntity.ok(LegacyAvailabilityResponse.success(completed));
        } catch (DataAccessException exception) { throw translate(exception); }
        catch (JsonProcessingException exception) { throw new AvailabilityException(400, "La ficha de revisión no tiene un formato válido."); }
    }

    private void apply(SessionPrincipal principal) { actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles()))); }
    private static String text(Object value, int max) { return value instanceof String text && !text.trim().isEmpty() && text.trim().length() <= max ? text.trim() : null; }
    private AvailabilityException translate(DataAccessException exception) {
        String detail = exception.getMostSpecificCause().getMessage();
        if (detail != null && detail.contains("ENCUENTRO_AJENO_O_INEXISTENTE")) return new AvailabilityException(404, "No se encontró un encuentro de revisión accesible.");
        if (detail != null && detail.contains("ENCUENTRO_CERRADO")) return new AvailabilityException(409, "La ficha de una atención cerrada no puede modificarse.");
        if (detail != null && detail.contains("ANTECEDENTE_REQUERIDO")) return new AvailabilityException(409, "Registra los antecedentes globales antes de cerrar la atención.");
        if (detail != null && detail.contains("MEDICO_REVISION_REQUERIDO")) return new AvailabilityException(403, "Solo el médico de revisión puede cerrar esta ficha.");
        return new AvailabilityException(400, "No se pudo completar la ficha de revisión.");
    }
}

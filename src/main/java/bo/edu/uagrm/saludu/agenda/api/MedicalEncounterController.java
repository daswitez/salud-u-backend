package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.agenda.application.ClinicalHistoryData;
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
import org.springframework.web.bind.annotation.GetMapping;
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
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
    @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<Map<String, Object>>> finalizeEncounter(
        @PathVariable UUID encounterId, @RequestBody Map<String, Object> body, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        String chiefComplaint = text(body.get("chiefComplaint"), 4000);
        String assessment = text(body.get("assessment"), 8000);
        String bloodStatus = text(body.get("bloodChemistryStatus"), 30);
        UUID referralSpecialtyId = uuid(body.get("referralSpecialtyId"));
        String referralReason = text(body.get("referralReason"), 2000);
        String referralComment = text(body.get("referralComment"), 4000);
        String referralPriority = text(body.get("referralPriority"), 20);
        boolean specialist = principal.roles().contains("SPECIALIST") && !principal.roles().contains("REVIEW_DOCTOR");
        if (chiefComplaint == null || assessment == null || (specialist && !(body.get("specialtyHistory") instanceof Map<?, ?>))) throw new AvailabilityException(400, specialist ? "El motivo de consulta, la evaluación y la ficha de especialidad son obligatorios." : "El motivo de consulta, la evaluación y la ficha de revisión son obligatorios.");
        if (referralSpecialtyId != null && (referralReason == null || referralComment == null)) throw new AvailabilityException(400, "Completa el motivo y el resumen para el especialista.");
        if (bloodStatus != null && !Set.of("ATTACHED","PENDING","NOT_PRESENTED").contains(bloodStatus)) throw new AvailabilityException(400,"Estado de química sanguínea inválido.");
        if (referralPriority != null && !Set.of("ROUTINE","PRIORITY","URGENT").contains(referralPriority)) throw new AvailabilityException(400,"Prioridad de derivación inválida.");
        apply(principal);
        try {
            String completed = specialist
                ? jdbcTemplate.queryForObject("select salud_u.finalizar_encuentro_especialidad(?, ?, ?, ?, ?, ?, cast(? as jsonb))", String.class, encounterId, chiefComplaint, assessment, text(body.get("instructions"), 8000), text(body.get("followUpText"), 4000), text(body.get("diagnosisText"), 2000), objectMapper.writeValueAsString(ClinicalHistoryData.specialty(objectMapper.valueToTree(body.get("specialtyHistory")))))
                : jdbcTemplate.queryForObject("select salud_u.finalizar_encuentro_revision(?, ?, ?, ?, ?, ?, ?, cast(? as jsonb), ?, ?, ?, ?)", String.class, encounterId, chiefComplaint, assessment, text(body.get("instructions"), 8000), text(body.get("followUpText"), 4000), bloodStatus == null ? "NOT_PRESENTED" : bloodStatus, text(body.get("diagnosisText"), 2000), objectMapper.writeValueAsString(ClinicalHistoryData.review(objectMapper.valueToTree(body.get("reviewHistory")))), referralSpecialtyId, referralReason, referralComment, referralPriority == null ? "ROUTINE" : referralPriority);
            Map<String, Object> contract = objectMapper.readValue(completed, Map.class);
            auditWriter.append(specialist ? "ENCUENTRO_ESPECIALIDAD_CERRADO" : "ENCUENTRO_REVISION_CERRADO", "encuentro_clinico", encounterId, AuditOutcome.SUCCESS, Map.of());
            return ResponseEntity.ok(LegacyAvailabilityResponse.success(contract));
        } catch (DataAccessException exception) { throw translate(exception); }
        catch (JsonProcessingException exception) { throw new AvailabilityException(400, "La ficha de revisión no tiene un formato válido."); }
    }

    @GetMapping("/{encounterId}/source-context")
    @PreAuthorize("hasRole('SPECIALIST')")
    @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<Object> sourceContext(@PathVariable UUID encounterId, @AuthenticationPrincipal SessionPrincipal principal) {
        apply(principal);
        try {
            String context = jdbcTemplate.queryForObject("select salud_u.contexto_origen_especialidad(?)::text", String.class, encounterId);
            return LegacyAvailabilityResponse.success(context == null ? null : objectMapper.readValue(context, Object.class));
        } catch (DataAccessException exception) { throw translate(exception); }
        catch (JsonProcessingException exception) { throw new AvailabilityException(400, "No se pudo leer el contexto de origen."); }
    }

    @GetMapping("/{encounterId}")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
    @Transactional
    public LegacyAvailabilityResponse<Object> context(@PathVariable UUID encounterId,@AuthenticationPrincipal SessionPrincipal principal) {
        apply(principal);
        try {
            Object data=objectMapper.readTree(jdbcTemplate.queryForObject("select salud_u.obtener_contexto_encuentro_propio(?)::text",String.class,encounterId));
            auditWriter.append("ENCUENTRO_CONSULTADO","encuentro_clinico",encounterId,AuditOutcome.SUCCESS,Map.of());
            return LegacyAvailabilityResponse.success(data);
        } catch(DataAccessException exception){throw translate(exception);}
        catch(JsonProcessingException exception){throw new AvailabilityException(500,"No se pudo leer la ficha de atención.");}
    }

    private void apply(SessionPrincipal principal) { actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles()))); }
    private static String text(Object value, int max) { if(!(value instanceof String text)||text.trim().isEmpty())return null;String trimmed=text.trim();return trimmed.substring(0,Math.min(max,trimmed.length())); }
    private static UUID uuid(Object value) { try { return value instanceof String text && !text.isBlank() ? UUID.fromString(text) : null; } catch (IllegalArgumentException exception) { throw new AvailabilityException(400, "La especialidad de derivación no es válida."); } }
    private AvailabilityException translate(DataAccessException exception) {
        String detail = exception.getMostSpecificCause().getMessage();
        if (detail != null && detail.contains("ENCUENTRO_AJENO_O_INEXISTENTE")) return new AvailabilityException(404, "No se encontró un encuentro de revisión accesible.");
        if (detail != null && detail.contains("No existe una ficha de personal activa")) return new AvailabilityException(404,"No se encontró un encuentro accesible.");
        if (detail != null && detail.contains("ENCUENTRO_CERRADO")) return new AvailabilityException(409, "La ficha de una atención cerrada no puede modificarse.");
        if (detail != null && detail.contains("ANTECEDENTE_REQUERIDO")) return new AvailabilityException(409, "Registra los antecedentes globales antes de cerrar la atención.");
        if (detail != null && detail.contains("QUIMICA_SANGUINEA_REQUERIDA")) return new AvailabilityException(409, "Adjunta una química sanguínea disponible antes de marcarla como presentada.");
        if (detail != null && detail.contains("CITA_NO_ATENDIBLE")) return new AvailabilityException(409, "La cita ya no puede marcarse como atendida.");
        if (detail != null && detail.contains("DERIVACION_INCOMPLETA")) return new AvailabilityException(400, "Completa especialidad, motivo, resumen y prioridad de la derivación.");
        if (detail != null && detail.contains("ESPECIALIDAD_NO_HABILITADA")) return new AvailabilityException(409, "La especialidad seleccionada no está habilitada.");
        if (detail != null && detail.contains("MEDICO_REVISION_REQUERIDO")) return new AvailabilityException(403, "Solo el médico de revisión puede cerrar esta ficha.");
        if (detail != null && detail.contains("ENCUENTRO_ESPECIALIDAD_AJENO")) return new AvailabilityException(404, "No se encontró una atención especializada accesible.");
        if (detail != null && detail.contains("FICHA_ESPECIALIDAD_INVALIDA") || detail != null && detail.contains("CAMPOS_CLINICOS_REQUERIDOS")) return new AvailabilityException(400, "La ficha de especialidad es inválida o está incompleta.");
        if (detail != null && detail.contains("FICHA_ESPECIALIDAD_AJENA")) return new AvailabilityException(409, "La ficha no corresponde a la especialidad de esta cita.");
        if (detail != null && detail.contains("PLANTILLA_ESPECIALIDAD_REQUERIDA")) return new AvailabilityException(409, "No hay una plantilla activa para esta especialidad.");
        return new AvailabilityException(400, "No se pudo completar la ficha de revisión.");
    }
}

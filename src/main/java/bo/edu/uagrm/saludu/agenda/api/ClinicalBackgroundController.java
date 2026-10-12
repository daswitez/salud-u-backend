package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/medical/patients")
public class ClinicalBackgroundController {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;
    private final ObjectMapper objectMapper;

    public ClinicalBackgroundController(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter, ObjectMapper objectMapper) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
        this.objectMapper = objectMapper;
    }

    @GetMapping("/{patientId}/clinical-background")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
    @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<Map<String, Object>> get(@PathVariable UUID patientId, @AuthenticationPrincipal SessionPrincipal principal) {
        apply(principal);
        try {
            List<Map<String, Object>> rows = jdbcTemplate.query("select * from salud_u.obtener_antecedentes_clinicos(?)", (rs, row) -> response(
                rs.getObject("id", UUID.class), rs.getInt("numero_version"), parse(rs.getString("datos")), rs.getString("estado_verificacion"),
                rs.getObject("registrado_en", OffsetDateTime.class), rs.getObject("registrado_por", UUID.class), rs.getString("motivo_cambio")
            ), patientId);
            return rows.isEmpty() ? LegacyAvailabilityResponse.success(null) : LegacyAvailabilityResponse.success(rows.getFirst());
        } catch (DataAccessException exception) { throw translate(exception); }
    }

    @PatchMapping("/{patientId}/clinical-background")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
    @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<Map<String, Object>>> save(
        @PathVariable UUID patientId, @RequestBody Map<String, Object> body, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        Object rawData = body.get("data");
        String reason = body.get("changeReason") instanceof String value ? value.trim() : "";
        int expectedVersion = body.get("expectedVersion") instanceof Number value ? value.intValue() : 0;
        UUID encounterId = body.get("encounterId") instanceof String value && !value.isBlank() ? UUID.fromString(value) : null;
        if (rawData == null || reason.isBlank() || reason.length() > 500 || expectedVersion < 0) throw new AvailabilityException(400, "Indica datos válidos y el motivo de actualización.");
        apply(principal);
        try {
            Map<String, Object> saved = jdbcTemplate.queryForObject(
                "select * from salud_u.guardar_antecedentes_clinicos(?, cast(? as jsonb), ?, ?, ?)",
                (rs, row) -> response(rs.getObject("id", UUID.class), rs.getInt("numero_version"), parse(rs.getString("datos")), rs.getString("estado_verificacion"), rs.getObject("registrado_en", OffsetDateTime.class), rs.getObject("registrado_por", UUID.class), rs.getString("motivo_cambio")),
                patientId, objectMapper.writeValueAsString(rawData), expectedVersion, encounterId, reason
            );
            auditWriter.append("ANTECEDENTE_CLINICO_VERSIONADO", "version_antecedente_clinico", (UUID) saved.get("id"), AuditOutcome.SUCCESS, Map.of("idPaciente", patientId.toString()));
            return ResponseEntity.ok(LegacyAvailabilityResponse.success(saved));
        } catch (DataAccessException exception) { throw translate(exception); }
        catch (JsonProcessingException exception) { throw new AvailabilityException(400, "Los antecedentes no tienen un formato válido."); }
    }

    private Map<String, Object> response(UUID id, int version, JsonNode data, String verificationStatus, OffsetDateTime recordedAt, UUID recordedBy, String changeReason) {
        return Map.of("id", id, "versionNo", version, "data", data, "verificationStatus", verificationStatus, "recordedAt", recordedAt, "recordedBy", recordedBy, "changeReason", changeReason);
    }

    private JsonNode parse(String json) {
        try { return objectMapper.readTree(json); }
        catch (JsonProcessingException exception) { throw new AvailabilityException(500, "No se pudo leer la versión de antecedentes."); }
    }

    private void apply(SessionPrincipal principal) { actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles()))); }

    private AvailabilityException translate(DataAccessException exception) {
        String detail = exception.getMostSpecificCause().getMessage();
        if (detail != null && detail.contains("PACIENTE_AJENO_O_INEXISTENTE")) return new AvailabilityException(404, "No se encontró un paciente accesible para este médico.");
        if (detail != null && detail.contains("VERSION_ANTECEDENTE_DESACTUALIZADA")) return new AvailabilityException(409, "Los antecedentes fueron actualizados por otro profesional. Recarga la información.");
        if (detail != null && detail.contains("ENCUENTRO_CERRADO")) return new AvailabilityException(409, "La atención cerrada conserva su versión anterior.");
        if (detail != null && detail.contains("MEDICO_NO_AUTORIZADO")) return new AvailabilityException(403, "No tiene permiso para consultar antecedentes clínicos.");
        return new AvailabilityException(400, "No se pudieron guardar los antecedentes clínicos.");
    }
}

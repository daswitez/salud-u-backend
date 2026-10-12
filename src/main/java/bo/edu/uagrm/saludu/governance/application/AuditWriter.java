package bo.edu.uagrm.saludu.governance.application;

import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

@Component
public class AuditWriter {
    private final JdbcTemplate jdbcTemplate;
    private final ObjectMapper objectMapper;

    public AuditWriter(JdbcTemplate jdbcTemplate, ObjectMapper objectMapper) {
        this.jdbcTemplate = jdbcTemplate;
        this.objectMapper = objectMapper;
    }

    public UUID append(String action, String resourceType, UUID resourceId, AuditOutcome outcome, Map<String, ?> details) {
        try {
            var json = objectMapper.writeValueAsString(details == null ? Map.of() : details);
            return jdbcTemplate.queryForObject(
                "select salud_u.agregar_evento_auditoria(?, ?, ?, ?, cast(? as jsonb))",
                UUID.class,
                action,
                resourceType,
                resourceId,
                outcome.name(),
                json
            );
        } catch (JsonProcessingException exception) {
            throw new IllegalArgumentException("Los detalles de auditoría no se pueden serializar.", exception);
        }
    }
}

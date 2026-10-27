package bo.edu.uagrm.saludu.scheduling.application;

import com.fasterxml.jackson.databind.JsonNode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/** Sugerencia de agenda tal como la ve Administración: códigos y claves de la API en inglés. */
public record ScheduleSuggestion(UUID id, String type, LocalDate date, UUID specialtyId, String specialtyName, UUID staffId,
    String staffName, JsonNode suggestedValue, String explanation, String modelVersion, OffsetDateTime expiresAt, String status,
    OffsetDateTime createdAt, OffsetDateTime updatedAt, Decision decision) {

    /** null mientras la sugerencia está pendiente; en EXPIRED no hay persona. */
    public record Decision(OffsetDateTime decidedAt, UUID decidedBy, String decidedByName, String reason, JsonNode appliedValue) {}
}

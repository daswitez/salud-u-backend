package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import com.fasterxml.jackson.databind.JsonNode;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/availability-slots")
public class AvailabilityController {
    private final AvailabilityService availabilityService;

    public AvailabilityController(AvailabilityService availabilityService) {
        this.availabilityService = availabilityService;
    }

    @GetMapping
    @PreAuthorize("hasAnyRole('ADMINISTRATIVE', 'REVIEW_DOCTOR', 'SPECIALIST')")
    public LegacyAvailabilityResponse<?> get(
        @RequestParam(defaultValue = "false") boolean manage, @RequestParam(defaultValue = "false") boolean initial,
        @RequestParam(required = false) LocalDate from, @RequestParam(required = false) LocalDate to,
        @AuthenticationPrincipal SessionPrincipal principal
    ) {
        if (manage) {
            LocalDate first = from == null ? LocalDate.now(java.time.ZoneId.of("America/La_Paz")) : from;
            LocalDate last = to == null ? first : to;
            if (last.isBefore(first)) throw new AvailabilityException(400, "El rango de fechas no es válido.");
            return LegacyAvailabilityResponse.success(availabilityService.management(principal, first, last));
        }
        return LegacyAvailabilityResponse.success(availabilityService.published(principal, initial));
    }

    @PostMapping
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR', 'SPECIALIST')")
    public ResponseEntity<?> post(@RequestBody JsonNode body, @AuthenticationPrincipal SessionPrincipal principal) {
        if (body.path("rules").isArray()) {
            int generated = availabilityService.replace(principal, body.path("rules"), body.path("recurringBlocks").isArray() ? body.path("recurringBlocks") : com.fasterxml.jackson.databind.node.JsonNodeFactory.instance.arrayNode());
            return ResponseEntity.ok(LegacyAvailabilityResponse.success(Map.of("generatedSlots", generated)));
        }
        if (body.path("dateBlock").asBoolean(false)) {
            LocalDate blockDate = date(body.path("blockDate").asText(null));
            LocalTime startsAt = timeOrNull(body.path("startsAt").asText(null));
            LocalTime endsAt = timeOrNull(body.path("endsAt").asText(null));
            String label = text(body.path("label").asText(null));
            if (blockDate == null || label == null || (startsAt == null) != (endsAt == null)) throw new AvailabilityException(400, "Completa fecha, motivo y ambas horas si el bloqueo no es de todo el día.");
            UUID id = availabilityService.createBlock(principal, blockDate, startsAt, endsAt, label);
            return ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(Map.of("id", id)));
        }
        OffsetDateTime startsAt = dateTime(body.path("startsAt").asText(null));
        OffsetDateTime endsAt = dateTime(body.path("endsAt").asText(null));
        int capacity = body.path("capacity").canConvertToInt() ? body.path("capacity").asInt() : -1;
        if (startsAt == null || endsAt == null || capacity < 0) throw new AvailabilityException(400, "Fecha, hora y capacidad son obligatorias.");
        UUID specialtyId = uuidOrNull(body.path("specialtyId").asText(null));
        UUID id = availabilityService.publish(principal, startsAt, endsAt, capacity, specialtyId);
        return ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(Map.of("id", id)));
    }

    @DeleteMapping
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR', 'SPECIALIST')")
    public LegacyAvailabilityResponse<Void> delete(@RequestParam(required = false) String blockId, @AuthenticationPrincipal SessionPrincipal principal) {
        UUID id = uuidOrNull(blockId);
        if (id == null) throw new AvailabilityException(400, "Indica el bloqueo a eliminar.");
        availabilityService.deleteBlock(principal, id);
        return LegacyAvailabilityResponse.success(null);
    }

    private static String text(String value) { return value == null || value.trim().isEmpty() ? null : value.trim(); }
    private static LocalDate date(String value) { try { return text(value) == null ? null : LocalDate.parse(value); } catch (RuntimeException exception) { return null; } }
    private static LocalTime timeOrNull(String value) { try { return text(value) == null ? null : LocalTime.parse(value); } catch (RuntimeException exception) { throw new AvailabilityException(400, "Completa fecha, motivo y ambas horas si el bloqueo no es de todo el día."); } }
    private static OffsetDateTime dateTime(String value) { try { return text(value) == null ? null : OffsetDateTime.parse(value); } catch (RuntimeException exception) { return null; } }
    private static UUID uuidOrNull(String value) { try { return text(value) == null ? null : UUID.fromString(value); } catch (RuntimeException exception) { return null; } }
}

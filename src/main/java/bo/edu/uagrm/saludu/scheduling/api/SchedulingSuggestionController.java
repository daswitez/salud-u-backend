package bo.edu.uagrm.saludu.scheduling.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.scheduling.application.ScheduleSuggestion;
import bo.edu.uagrm.saludu.scheduling.application.ScheduleSuggestionService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@PreAuthorize("hasRole('ADMINISTRATIVE')")
public class SchedulingSuggestionController {
    private final ScheduleSuggestionService suggestions;

    public SchedulingSuggestionController(ScheduleSuggestionService suggestions) { this.suggestions = suggestions; }

    /** Sugerencias de una fecha (por defecto, hoy en Bolivia). Las alertas de capacidad llevan la fecha en que empieza su horizonte. */
    @GetMapping("/api/scheduling/suggestions")
    public ResponseEntity<LegacyAvailabilityResponse<List<ScheduleSuggestion>>> list(@RequestParam(required = false) String date,
        @AuthenticationPrincipal SessionPrincipal principal) {
        LocalDate day;
        try { day = date == null ? LocalDate.now(ZoneId.of("America/La_Paz")) : LocalDate.parse(date); }
        catch (DateTimeParseException exception) { throw new AvailabilityException(400, "La fecha debe tener el formato AAAA-MM-DD."); }
        return ResponseEntity.ok().header("Cache-Control", "no-store, private").body(LegacyAvailabilityResponse.success(suggestions.list(principal, day)));
    }

    /**
     * O-06: {"decision": ACCEPTED | MODIFIED | REJECTED, "reason": texto, "slots": [{"slotId", "capacity"}]}. El motivo es
     * obligatorio salvo al aceptar; slots solo va con MODIFIED de un OVERBOOKING, con la capacidad final de cada cupo.
     */
    @PostMapping("/api/scheduling/suggestions/{id}/decision")
    public ResponseEntity<LegacyAvailabilityResponse<ScheduleSuggestion>> decide(@PathVariable UUID id, @RequestBody JsonNode body,
        @AuthenticationPrincipal SessionPrincipal principal) {
        if (!onlyFields(body, Set.of("decision", "reason", "slots")) || !body.path("decision").isTextual()
            || !(body.path("reason").isMissingNode() || body.path("reason").isNull() || body.path("reason").isTextual()))
            throw invalidDecision();
        ArrayNode slots = null;
        if (body.has("slots") && !body.get("slots").isNull()) {
            if (!body.get("slots").isArray() || body.get("slots").isEmpty() || body.get("slots").size() > 20) throw invalidDecision();
            slots = JsonNodeFactory.instance.arrayNode();
            Set<String> seen = new HashSet<>();
            for (JsonNode slot : body.get("slots")) {
                if (!onlyFields(slot, Set.of("slotId", "capacity")) || !slot.path("slotId").isTextual() || !slot.path("capacity").isIntegralNumber()
                    || !seen.add(slot.path("slotId").textValue())) throw invalidDecision();
                try { UUID.fromString(slot.path("slotId").textValue()); } catch (IllegalArgumentException exception) { throw invalidDecision(); }
                slots.addObject().put("id_cupo", slot.path("slotId").textValue()).put("capacidad", slot.path("capacity").intValue());
            }
        }
        ScheduleSuggestion decided = suggestions.decide(principal, id, body.path("decision").textValue(),
            body.path("reason").isTextual() ? body.path("reason").textValue() : null, slots);
        return ResponseEntity.ok().header("Cache-Control", "no-store, private").body(LegacyAvailabilityResponse.success(decided));
    }

    private static boolean onlyFields(JsonNode body, Set<String> allowed) {
        if (body == null || !body.isObject()) return false;
        for (var names = body.fieldNames(); names.hasNext(); ) if (!allowed.contains(names.next())) return false;
        return true;
    }

    private static AvailabilityException invalidDecision() {
        return new AvailabilityException(400, "Indica la decisión (ACCEPTED, MODIFIED o REJECTED), el motivo y, si modificas un sobrecupo, la capacidad de cada cupo.");
    }
}

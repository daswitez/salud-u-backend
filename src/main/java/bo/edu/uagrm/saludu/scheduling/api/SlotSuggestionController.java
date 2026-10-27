package bo.edu.uagrm.saludu.scheduling.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.scheduling.application.SlotSuggestionService;
import bo.edu.uagrm.saludu.scheduling.application.SuggestedSlots;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
@PreAuthorize("hasRole('ADMINISTRATIVE')")
public class SlotSuggestionController {
    private final SlotSuggestionService suggestions;

    public SlotSuggestionController(SlotSuggestionService suggestions) { this.suggestions = suggestions; }

    /** Los tres mejores cupos para asignar la solicitud. Solo consulta: se asigna con POST .../assign. */
    @GetMapping("/api/appointment-requests/{requestId}/suggested-slots")
    public ResponseEntity<LegacyAvailabilityResponse<SuggestedSlots>> suggest(@PathVariable UUID requestId,
        @AuthenticationPrincipal SessionPrincipal principal) {
        return ResponseEntity.ok().header("Cache-Control", "no-store, private").body(LegacyAvailabilityResponse.success(suggestions.suggest(principal, requestId)));
    }
}

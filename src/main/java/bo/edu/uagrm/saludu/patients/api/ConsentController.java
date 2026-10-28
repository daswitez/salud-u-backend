package bo.edu.uagrm.saludu.patients.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.patients.application.ConsentAnswer;
import bo.edu.uagrm.saludu.patients.application.ConsentService;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/** A-03: el estudiante responde por el portal; Administración registra lo que el paciente responde en recepción. */
@RestController
public class ConsentController {
    private final ConsentService consents;

    public ConsentController(ConsentService consents) { this.consents = consents; }

    @GetMapping("/api/consent-texts") @PreAuthorize("hasRole('ADMINISTRATIVE')")
    public ResponseEntity<LegacyAvailabilityResponse<Object>> currentTexts(@AuthenticationPrincipal SessionPrincipal principal) {
        return response(consents.currentTexts(principal));
    }

    @GetMapping("/api/me/consents") @PreAuthorize("hasRole('STUDENT')")
    public ResponseEntity<LegacyAvailabilityResponse<Object>> mine(@AuthenticationPrincipal SessionPrincipal principal) {
        return response(consents.mine(principal));
    }

    @PostMapping("/api/me/consents") @PreAuthorize("hasRole('STUDENT')")
    public ResponseEntity<LegacyAvailabilityResponse<Object>> answerMine(@RequestBody ConsentAnswer answer, @AuthenticationPrincipal SessionPrincipal principal) {
        return response(consents.saveMine(principal, answer));
    }

    @GetMapping("/api/patients/{patientId}/consents") @PreAuthorize("hasRole('ADMINISTRATIVE')")
    public ResponseEntity<LegacyAvailabilityResponse<Object>> patient(@PathVariable UUID patientId, @AuthenticationPrincipal SessionPrincipal principal) {
        return response(consents.forPatient(principal, patientId));
    }

    @PostMapping("/api/patients/{patientId}/consents") @PreAuthorize("hasRole('ADMINISTRATIVE')")
    public ResponseEntity<LegacyAvailabilityResponse<Object>> answerForPatient(@PathVariable UUID patientId, @RequestBody ConsentAnswer answer,
        @AuthenticationPrincipal SessionPrincipal principal) {
        return response(consents.saveForPatient(principal, patientId, answer));
    }

    private static ResponseEntity<LegacyAvailabilityResponse<Object>> response(Object data) {
        return ResponseEntity.ok().header("Cache-Control", "no-store, private").body(LegacyAvailabilityResponse.success(data));
    }
}

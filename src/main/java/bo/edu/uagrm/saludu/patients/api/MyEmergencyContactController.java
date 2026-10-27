package bo.edu.uagrm.saludu.patients.api;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.patients.application.EmergencyContact;
import bo.edu.uagrm.saludu.patients.application.PatientService;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** A-02: el estudiante ve y edita el contacto de emergencia de su propia ficha. data es null si no tiene. */
@RestController
@RequestMapping("/api/me/emergency-contact")
@PreAuthorize("hasRole('STUDENT')")
public class MyEmergencyContactController {
    private final PatientService patients;

    public MyEmergencyContactController(PatientService patients) { this.patients = patients; }

    @GetMapping
    public ResponseEntity<Response> get(@AuthenticationPrincipal SessionPrincipal principal) {
        return response(patients.myEmergencyContact(principal));
    }

    /** {"fullName", "relationship", "phone"}. */
    @PutMapping
    public ResponseEntity<Response> put(@RequestBody JsonNode body, @AuthenticationPrincipal SessionPrincipal principal) {
        return response(patients.saveMyEmergencyContact(principal, EmergencyContact.parse(body)));
    }

    private static ResponseEntity<Response> response(EmergencyContact contact) {
        return ResponseEntity.ok().header("Cache-Control", "no-store, private").body(new Response(true, contact));
    }

    /** Misma forma que LegacyPatientResponse, pero data se envía siempre: null significa que no hay contacto. */
    public record Response(boolean ok, @JsonInclude(JsonInclude.Include.ALWAYS) EmergencyContact data) {}
}

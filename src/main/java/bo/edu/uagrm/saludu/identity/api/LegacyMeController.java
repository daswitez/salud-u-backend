package bo.edu.uagrm.saludu.identity.api;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class LegacyMeController {
    @GetMapping("/api/me")
    public LegacyMeResponse me(@AuthenticationPrincipal SessionPrincipal principal) {
        return new LegacyMeResponse(true, SessionUserResponse.from(principal));
    }
}

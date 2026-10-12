package bo.edu.uagrm.saludu.shared.api;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.util.Comparator;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.security.web.csrf.CsrfTokenRepository;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1")
public class ApiSessionController {
    private final CsrfTokenRepository csrfTokenRepository;

    public ApiSessionController(CsrfTokenRepository csrfTokenRepository) {
        this.csrfTokenRepository = csrfTokenRepository;
    }

    @GetMapping("/security/csrf")
    public ResponseEntity<ApiEnvelope<CsrfTokenResponse>> csrf(HttpServletRequest request, HttpServletResponse response) {
        CsrfToken token = csrfTokenRepository.loadToken(request);
        if (token == null) {
            token = csrfTokenRepository.generateToken(request);
            csrfTokenRepository.saveToken(token, request, response);
        }
        var data = new CsrfTokenResponse(token.getToken(), token.getHeaderName(), token.getParameterName());
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(ApiEnvelope.success(data));
    }

    @GetMapping("/session")
    public ApiEnvelope<SessionProbeResponse> session(Authentication authentication) {
        var authorities = authentication.getAuthorities().stream()
            .map(authority -> authority.getAuthority())
            .sorted(Comparator.naturalOrder())
            .toList();
        return ApiEnvelope.success(new SessionProbeResponse(authentication.getName(), authorities));
    }
}

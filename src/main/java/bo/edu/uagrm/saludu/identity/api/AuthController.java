package bo.edu.uagrm.saludu.identity.api;

import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.shared.api.ApiEnvelope;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/auth")
public class AuthController {
    private final AuthenticationService authenticationService;
    private final SessionCookieService cookies;

    public AuthController(AuthenticationService authenticationService, SessionCookieService cookies) {
        this.authenticationService = authenticationService;
        this.cookies = cookies;
    }

    @PostMapping("/login")
    public ResponseEntity<ApiEnvelope<LoginResponse>> login(@Valid @RequestBody LoginRequest request, HttpServletResponse response) {
        var session = authenticationService.login(request.email(), request.password());
        if (session.challenge() != null) {
            // SEG-2FA: contraseña correcta, todavía sin sesión.
            cookies.writeChallenge(session.token(), response);
            return ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .body(ApiEnvelope.success(LoginResponse.secondFactor(session.challenge().enrollmentRequired())));
        }
        cookies.write(session.token(), response);
        return ResponseEntity.ok()
            .cacheControl(CacheControl.noStore())
            .body(ApiEnvelope.success(new LoginResponse(SessionUserResponse.from(session.principal()))));
    }
}

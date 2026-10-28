package bo.edu.uagrm.saludu.identity.api;

import bo.edu.uagrm.saludu.identity.application.SecondFactorException;
import bo.edu.uagrm.saludu.identity.application.SecondFactorService;
import bo.edu.uagrm.saludu.identity.application.SecondFactorService.Outcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiEnvelope;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/** SEG-2FA: segundo paso del ingreso, activación, códigos de recuperación del perfil y restablecimiento por Administración. */
@RestController
public class SecondFactorController {
    private final SecondFactorService secondFactor;
    private final SessionCookieService cookies;

    public SecondFactorController(SecondFactorService secondFactor, SessionCookieService cookies) {
        this.secondFactor = secondFactor;
        this.cookies = cookies;
    }

    @PostMapping("/api/v1/auth/second-factor")
    public ResponseEntity<ApiEnvelope<LoginResponse>> verify(@Valid @RequestBody SecondFactorRequest body, HttpServletRequest request, HttpServletResponse response) {
        Outcome outcome = secondFactor.verify(challenge(request), body.code(), body.recoveryCode());
        return session(outcome, response, null);
    }

    @PostMapping("/api/v1/auth/second-factor/enrollment")
    public ResponseEntity<ApiEnvelope<Map<String, String>>> enroll(HttpServletRequest request) {
        var enrollment = secondFactor.enroll(challenge(request));
        if (enrollment == null) throw challengeInvalid();
        // El secreto se entrega una sola vez; no se puede volver a consultar.
        return ResponseEntity.ok().cacheControl(CacheControl.noStore())
            .body(ApiEnvelope.success(Map.of("otpauthUri", enrollment.otpauthUri(), "secret", enrollment.secret())));
    }

    @PostMapping("/api/v1/auth/second-factor/enrollment/confirm")
    public ResponseEntity<ApiEnvelope<LoginResponse>> confirm(@Valid @RequestBody SecondFactorRequest body, HttpServletRequest request, HttpServletResponse response) {
        Outcome outcome = secondFactor.confirmEnrollment(challenge(request), body.code());
        return session(outcome, response, outcome.recoveryCodes());
    }

    @GetMapping("/api/v1/profile/second-factor")
    public ResponseEntity<ApiEnvelope<SecondFactorService.ProfileStatus>> status(@AuthenticationPrincipal SessionPrincipal principal) {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(ApiEnvelope.success(secondFactor.status(principal)));
    }

    @PostMapping("/api/v1/profile/second-factor/recovery-codes")
    public ResponseEntity<ApiEnvelope<Map<String, List<String>>>> regenerate(@Valid @RequestBody SecondFactorRequest body, @AuthenticationPrincipal SessionPrincipal principal) {
        var result = secondFactor.regenerateRecoveryCodes(principal, body.code());
        switch (result.status()) {
            case AUTHENTICATED -> {
                return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(ApiEnvelope.success(Map.of("recoveryCodes", result.recoveryCodes())));
            }
            case LOCKED -> throw locked();
            case FAILED -> throw invalidCode();
            default -> throw new SecondFactorException(HttpStatus.CONFLICT, "SECOND_FACTOR_NOT_ENABLED", "Tu cuenta no tiene el segundo factor activo.");
        }
    }

    @PostMapping("/api/v1/admin/users/{principalId}/second-factor/reset")
    @PreAuthorize("hasRole('ADMINISTRATIVE')")
    public ResponseEntity<ApiEnvelope<Map<String, Boolean>>> reset(@PathVariable UUID principalId, @AuthenticationPrincipal SessionPrincipal principal) {
        if (principal.id().equals(principalId)) throw selfReset();
        try {
            if (!secondFactor.reset(principal, principalId)) {
                throw new SecondFactorException(HttpStatus.NOT_FOUND, "PRINCIPAL_NOT_FOUND", "La cuenta no existe.");
            }
        } catch (SecondFactorService.SelfResetException exception) {
            throw selfReset();
        }
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(ApiEnvelope.success(Map.of("reset", true)));
    }

    private ResponseEntity<ApiEnvelope<LoginResponse>> session(Outcome outcome, HttpServletResponse response, List<String> recoveryCodes) {
        switch (outcome.status()) {
            case AUTHENTICATED -> {
                cookies.clearChallenge(response);
                cookies.write(outcome.session().token(), response);
                var user = SessionUserResponse.from(outcome.session().principal());
                return ResponseEntity.ok().cacheControl(CacheControl.noStore())
                    .body(ApiEnvelope.success(new LoginResponse(user, null, null, recoveryCodes == null || recoveryCodes.isEmpty() ? null : recoveryCodes)));
            }
            case FAILED -> throw invalidCode();
            case LOCKED -> throw locked();
            case WRONG_STEP -> throw new SecondFactorException(HttpStatus.CONFLICT, "SECOND_FACTOR_ENROLLMENT_NOT_STARTED", "Primero genera el código QR de activación.");
            default -> {
                cookies.clearChallenge(response);
                throw challengeInvalid();
            }
        }
    }

    private String challenge(HttpServletRequest request) {
        return cookies.readChallenge(request).orElseThrow(SecondFactorController::challengeInvalid);
    }

    private static SecondFactorException challengeInvalid() {
        return new SecondFactorException(HttpStatus.UNAUTHORIZED, "SECOND_FACTOR_CHALLENGE_INVALID", "La verificación venció o ya se usó. Vuelve a ingresar tu correo y contraseña.");
    }

    private static SecondFactorException invalidCode() {
        return new SecondFactorException(HttpStatus.UNAUTHORIZED, "SECOND_FACTOR_INVALID", "El código no es válido. Revisa la hora del celular y usa el código vigente.");
    }

    private static SecondFactorException locked() {
        return new SecondFactorException(HttpStatus.TOO_MANY_REQUESTS, "SECOND_FACTOR_LOCKED", "Demasiados códigos incorrectos. Espera 15 minutos o pide a Administración que restablezca tu segundo factor.");
    }

    private static SecondFactorException selfReset() {
        return new SecondFactorException(HttpStatus.FORBIDDEN, "SECOND_FACTOR_SELF_RESET", "No puedes restablecer tu propio segundo factor.");
    }
}

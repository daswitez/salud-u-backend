package bo.edu.uagrm.saludu.identity.infrastructure;

import bo.edu.uagrm.saludu.identity.application.AuthProperties;
import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.util.Arrays;
import java.util.Optional;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseCookie;
import org.springframework.stereotype.Component;

@Component
public class SessionCookieService {
    public static final String COOKIE_NAME = "SALUD_U_SESSION";
    /** SEG-2FA: desafío entre la contraseña y el segundo factor. Solo viaja a /api/v1/auth y vence a los 5 minutos. */
    public static final String CHALLENGE_COOKIE_NAME = "SALUD_U_2FA";
    private final AuthProperties properties;

    public SessionCookieService(AuthProperties properties) {
        this.properties = properties;
    }

    public void write(String token, HttpServletResponse response) {
        response.addHeader(HttpHeaders.SET_COOKIE, cookie(token).maxAge(properties.getSessionTtl()).build().toString());
    }

    public void clear(HttpServletResponse response) {
        response.addHeader(HttpHeaders.SET_COOKIE, cookie("").maxAge(java.time.Duration.ZERO).build().toString());
    }

    public void writeChallenge(String token, HttpServletResponse response) {
        response.addHeader(HttpHeaders.SET_COOKIE, challengeCookie(token).maxAge(properties.getSecondFactorChallengeTtl()).build().toString());
    }

    public void clearChallenge(HttpServletResponse response) {
        response.addHeader(HttpHeaders.SET_COOKIE, challengeCookie("").maxAge(java.time.Duration.ZERO).build().toString());
    }

    public Optional<String> readChallenge(HttpServletRequest request) {
        return read(request, CHALLENGE_COOKIE_NAME);
    }

    public Optional<String> read(HttpServletRequest request) {
        return read(request, COOKIE_NAME);
    }

    private static Optional<String> read(HttpServletRequest request, String name) {
        if (request.getCookies() == null) {
            return Optional.empty();
        }
        return Arrays.stream(request.getCookies())
            .filter(cookie -> name.equals(cookie.getName()))
            .map(Cookie::getValue)
            .filter(value -> !value.isBlank())
            .findFirst();
    }

    private ResponseCookie.ResponseCookieBuilder cookie(String value) {
        return ResponseCookie.from(COOKIE_NAME, value)
            .httpOnly(true)
            .secure(properties.isCookieSecure())
            .sameSite("Lax")
            .path("/");
    }

    private ResponseCookie.ResponseCookieBuilder challengeCookie(String value) {
        return ResponseCookie.from(CHALLENGE_COOKIE_NAME, value)
            .httpOnly(true)
            .secure(properties.isCookieSecure())
            .sameSite("Strict")
            .path("/api/v1/auth");
    }
}

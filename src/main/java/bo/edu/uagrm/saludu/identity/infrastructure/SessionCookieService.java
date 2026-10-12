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

    public Optional<String> read(HttpServletRequest request) {
        if (request.getCookies() == null) {
            return Optional.empty();
        }
        return Arrays.stream(request.getCookies())
            .filter(cookie -> COOKIE_NAME.equals(cookie.getName()))
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
}

package bo.edu.uagrm.saludu.identity.infrastructure;

import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.security.core.Authentication;
import org.springframework.security.web.authentication.logout.LogoutHandler;
import org.springframework.stereotype.Component;

@Component
public class PersistentSessionLogoutHandler implements LogoutHandler {
    private final AuthenticationService authenticationService;
    private final SessionCookieService cookies;

    public PersistentSessionLogoutHandler(AuthenticationService authenticationService, SessionCookieService cookies) {
        this.authenticationService = authenticationService;
        this.cookies = cookies;
    }

    @Override
    public void logout(HttpServletRequest request, HttpServletResponse response, Authentication authentication) {
        try {
            cookies.read(request).ifPresent(authenticationService::revoke);
        } finally {
            cookies.clear(response);
        }
    }
}

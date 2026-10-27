package bo.edu.uagrm.saludu.identity.infrastructure;

import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Optional;
import org.springframework.dao.DataAccessException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class SessionAuthenticationFilter extends OncePerRequestFilter {
    private final AuthenticationService authenticationService;
    private final SessionCookieService cookies;
    private final ApiSecurityErrorWriter errors;

    public SessionAuthenticationFilter(AuthenticationService authenticationService, SessionCookieService cookies, ApiSecurityErrorWriter errors) {
        this.authenticationService = authenticationService;
        this.cookies = cookies;
        this.errors = errors;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
        if (SecurityContextHolder.getContext().getAuthentication() == null) {
            Optional<String> token = cookies.read(request);
            if (token.isPresent()) {
                Optional<SessionPrincipal> principal;
                try {
                    principal = authenticationService.resolve(token.get());
                } catch (DataAccessException exception) {
                    // Sin base de datos no se puede validar la sesión: no es una sesión vencida, así que se conserva la cookie.
                    errors.write(request, response, HttpServletResponse.SC_SERVICE_UNAVAILABLE, "SERVICE_UNAVAILABLE",
                        "El servicio no está disponible en este momento. Lo que escribiste se conserva; vuelve a intentar en unos segundos.");
                    return;
                }
                principal.ifPresentOrElse(value -> {
                    var authorities = value.roles().stream().map(role -> new SimpleGrantedAuthority("ROLE_" + role)).toList();
                    SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(value, null, authorities));
                }, () -> cookies.clear(response));
            }
        }
        chain.doFilter(request, response);
    }
}

package bo.edu.uagrm.saludu.identity.infrastructure;

import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class SessionAuthenticationFilter extends OncePerRequestFilter {
    private final AuthenticationService authenticationService;
    private final SessionCookieService cookies;

    public SessionAuthenticationFilter(AuthenticationService authenticationService, SessionCookieService cookies) {
        this.authenticationService = authenticationService;
        this.cookies = cookies;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
        if (SecurityContextHolder.getContext().getAuthentication() == null) {
            cookies.read(request).ifPresent(token -> authenticationService.resolve(token).ifPresentOrElse(principal -> {
                var authorities = principal.roles().stream().map(role -> new SimpleGrantedAuthority("ROLE_" + role)).toList();
                var authentication = new UsernamePasswordAuthenticationToken(principal, null, authorities);
                SecurityContextHolder.getContext().setAuthentication(authentication);
            }, () -> cookies.clear(response)));
        }
        chain.doFilter(request, response);
    }
}

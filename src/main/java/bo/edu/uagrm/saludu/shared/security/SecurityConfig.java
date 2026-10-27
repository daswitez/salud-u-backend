package bo.edu.uagrm.saludu.shared.security;

import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.identity.application.AuthProperties;
import bo.edu.uagrm.saludu.identity.infrastructure.PersistentSessionLogoutHandler;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionAuthenticationFilter;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.security.web.csrf.CsrfTokenRepository;
import org.springframework.security.web.csrf.CsrfTokenRequestAttributeHandler;
import org.springframework.security.web.csrf.CookieCsrfTokenRepository;
import org.springframework.security.web.csrf.InvalidCsrfTokenException;
import org.springframework.security.web.csrf.MissingCsrfTokenException;

@Configuration
@EnableMethodSecurity
@EnableConfigurationProperties(AuthProperties.class)
public class SecurityConfig {
    @Bean
    CsrfTokenRepository csrfTokenRepository() {
        // No usar HttpSession: su cookie compite con la sesión opaca de dominio
        // y rompe la continuidad del token al atravesar el proxy de Next.
        CookieCsrfTokenRepository repository = CookieCsrfTokenRepository.withHttpOnlyFalse();
        repository.setCookieName("SALUD_U_CSRF");
        repository.setHeaderName("X-CSRF-TOKEN");
        repository.setCookiePath("/");
        return repository;
    }

    @Bean
    SecurityFilterChain securityFilterChain(
        HttpSecurity http,
        CsrfTokenRepository csrfTokenRepository,
        ApiSecurityErrorWriter errors,
        ObjectProvider<SessionAuthenticationFilter> sessionAuthenticationFilter,
        ObjectProvider<PersistentSessionLogoutHandler> persistentSessionLogoutHandler
    ) throws Exception {
        sessionAuthenticationFilter.ifAvailable(filter -> http.addFilterBefore(filter, UsernamePasswordAuthenticationFilter.class));
        return http
                .csrf(csrf -> csrf
                        .csrfTokenRepository(csrfTokenRepository)
                        // El endpoint /security/csrf entrega el token del repositorio;
                        // conservarlo sin ofuscación permite que navegador y SSR lo
                        // reenvíen de forma determinista en X-CSRF-TOKEN.
                        .csrfTokenRequestHandler(new CsrfTokenRequestAttributeHandler()))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/api/notifications", "/api/notifications/**", "/api/me/notification-preferences", "/api/me/emergency-contact", "/api/me/consents").authenticated()
                        .requestMatchers("/api/administrative/referrals", "/api/medical/assigned-referrals/**").authenticated()
                        .requestMatchers("/api/medical/referrals", "/api/medical/referrals/**").authenticated()
                        .requestMatchers("/actuator/health", "/actuator/health/**", "/openapi/**", "/api/health", "/api/v1/security/csrf").permitAll()
                        .requestMatchers("/api/careers").permitAll()
                        .requestMatchers("/api/v1/auth/login", "/api/v1/session/logout").permitAll()
                        .requestMatchers("/api/v1/session", "/api/me", "/api/specialties", "/api/my-specialties", "/api/v1/catalogs/**", "/api/v1/admin/**", "/api/v1/profile/**", "/api/patients/**", "/api/availability-slots/**", "/api/appointment-requests/**", "/api/appointments/**", "/api/medical/appointments/**", "/api/medical/patients/**", "/api/medical/encounters/**", "/api/medical/documents/**", "/api/reports/**", "/api/research/**", "/api/audit-events/**", "/api/vaccines/**", "/api/vaccinations/**", "/api/vaccination-card", "/api/academic-periods", "/api/scheduling/initial-values", "/api/scheduling/suggestions", "/api/scheduling/suggestions/**", "/api/scheduling/block-proposals", "/api/scheduling/block-proposals/**", "/api/scheduling/metrics").authenticated()
                        .anyRequest().denyAll())
                .formLogin(form -> form.disable())
                .httpBasic(basic -> basic.disable())
                .logout(logout -> logout
                        .logoutUrl("/api/v1/session/logout")
                        .addLogoutHandler((request, response, authentication) -> persistentSessionLogoutHandler.ifAvailable(
                            handler -> handler.logout(request, response, authentication)
                        ))
                        .logoutSuccessHandler((request, response, authentication) -> response.setStatus(HttpServletResponse.SC_NO_CONTENT))
                        .permitAll())
                .exceptionHandling(errorHandling -> errorHandling
                        .authenticationEntryPoint((request, response, exception) ->
                                errors.write(request, response, HttpServletResponse.SC_UNAUTHORIZED, "UNAUTHENTICATED", "Se requiere una sesión autenticada."))
                        .accessDeniedHandler((request, response, exception) -> {
                            boolean csrf = exception instanceof InvalidCsrfTokenException || exception instanceof MissingCsrfTokenException;
                            errors.write(
                                request,
                                response,
                                HttpServletResponse.SC_FORBIDDEN,
                                csrf ? "CSRF_INVALID" : "FORBIDDEN",
                                csrf ? "El token CSRF falta, expiró o no es válido." : "No tiene permiso para esta operación."
                            );
                        }))
                .build();
    }
}

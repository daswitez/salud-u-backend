package bo.edu.uagrm.saludu.governance.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(AuditEventController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class AuditEventControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuditWriter auditWriter;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void auditorCanReadTheAuditEnvelope() throws Exception {
        mvc.perform(get("/api/audit-events").param("from", "2026-01-01").param("outcome", "SUCCESS").with(authentication(authenticationFor("AUDITOR"))))
            .andExpect(status().isOk()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data").isArray());
        verify(actorContext).apply(any());
        verify(auditWriter).append(any(), any(), any(), any(), any());
    }

    @Test
    void nonAuditorCannotReadAuditEvents() throws Exception {
        mvc.perform(get("/api/audit-events").with(authentication(authenticationFor("ADMINISTRATIVE")))).andExpect(status().isForbidden());
    }

    @Test
    void invalidDateRangeIsRejectedWithoutDatabaseAccess() throws Exception {
        mvc.perform(get("/api/audit-events").param("from", "2026-12-31").param("to", "2026-01-01").with(authentication(authenticationFor("AUDITOR"))))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.ok").value(false));
    }

    private static UsernamePasswordAuthenticationToken authenticationFor(String role) {
        SessionPrincipal principal = new SessionPrincipal(UUID.randomUUID(), "audit@example.invalid", "Auditor", List.of(role));
        return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
    }
}

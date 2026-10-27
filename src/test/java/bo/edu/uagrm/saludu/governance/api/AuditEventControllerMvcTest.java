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

    @Test void invalidCursorOutcomeAndLimitAreRejected() throws Exception {
        for(String[] param:List.of(new String[]{"outcome","UNKNOWN"},new String[]{"limit","501"},new String[]{"before","invalid"},new String[]{"actor","x".repeat(201)}))mvc.perform(get("/api/audit-events").param("paginated","true").param(param[0],param[1]).with(authentication(authenticationFor("AUDITOR")))).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        org.mockito.Mockito.verifyNoInteractions(jdbc,auditWriter);
    }
    @Test void paginationPreservesTimestampCursorAndErrorsNeverBecomeEmptySuccess() throws Exception {
        var timestamp=java.time.OffsetDateTime.parse("2026-10-26T02:30:00.123456Z");UUID id=UUID.randomUUID();
        org.mockito.Mockito.when(jdbc.query(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.RowMapper.class),org.mockito.ArgumentMatchers.any(Object[].class))).thenReturn(List.of(java.util.Map.of("id",id,"occurredAt",timestamp),java.util.Map.of("id",UUID.randomUUID(),"occurredAt",timestamp)));
        mvc.perform(get("/api/audit-events").param("paginated","true").param("limit","1").with(authentication(authenticationFor("AUDITOR")))).andExpect(status().isOk()).andExpect(jsonPath("$.pagination.hasMore").value(true)).andExpect(jsonPath("$.pagination.nextCursor").value(timestamp+"|"+id)).andExpect(jsonPath("$.data.length()").value(1)).andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.header().string("Cache-Control","no-store, private"));
        org.mockito.Mockito.when(jdbc.query(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.RowMapper.class),org.mockito.ArgumentMatchers.any(Object[].class))).thenThrow(new org.springframework.dao.DataAccessResourceFailureException("private detail"));mvc.perform(get("/api/audit-events").with(authentication(authenticationFor("AUDITOR")))).andExpect(status().isInternalServerError()).andExpect(jsonPath("$.error").isString());
    }
    @Test void allNonAuditorsAndAnonymousAreRejected() throws Exception {
        for(String role:List.of("STUDENT","REPORTING_OFFICER","SPECIALIST","REVIEW_DOCTOR"))mvc.perform(get("/api/audit-events").with(authentication(authenticationFor(role)))).andExpect(status().isForbidden());
        mvc.perform(get("/api/audit-events")).andExpect(status().isUnauthorized());
    }
    @Test void evidenceHasNoRuntimeMutationEndpoint() throws Exception {
        for(var method:List.of(org.springframework.http.HttpMethod.POST,org.springframework.http.HttpMethod.PATCH,org.springframework.http.HttpMethod.DELETE))
            mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.request(method,"/api/audit-events").with(authentication(authenticationFor("AUDITOR"))).with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf()))
                .andExpect(status().isMethodNotAllowed()).andExpect(jsonPath("$.error").isString());
        org.mockito.Mockito.verifyNoInteractions(jdbc,auditWriter);
    }
    private static UsernamePasswordAuthenticationToken authenticationFor(String role) {
        SessionPrincipal principal = new SessionPrincipal(UUID.randomUUID(), "audit@example.invalid", "Auditor", List.of(role));
        return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
    }
}

package bo.edu.uagrm.saludu.reports.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

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

@WebMvcTest(InstitutionalComplianceController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class InstitutionalComplianceControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean bo.edu.uagrm.saludu.governance.application.AuditWriter audit;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void administrativeActorReceivesTheLegacyComplianceEnvelope() throws Exception {
        mvc.perform(get("/api/reports/compliance").param("period", "2026-2").with(authentication(authenticationFor("ADMINISTRATIVE"))))
            .andExpect(status().isOk()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data").isArray());
        verify(actorContext).apply(any());
    }

    @Test
    void clinicianCannotReadInstitutionalCompliance() throws Exception {
        mvc.perform(get("/api/reports/compliance").with(authentication(authenticationFor("REVIEW_DOCTOR")))).andExpect(status().isForbidden());
    }

    @Test
    void rejectsInvalidActivityRangeBeforeQueryingDatabase() throws Exception {
        mvc.perform(get("/api/reports/daily-activity").param("from", "2026-12-31").param("to", "2026-01-01").with(authentication(authenticationFor("REPORTING_OFFICER"))))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.ok").value(false));
    }

    @Test void errorsAreRecoverableAndSummaryIsAdministrativeOnly() throws Exception {
        org.mockito.Mockito.when(jdbc.query(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.RowMapper.class),org.mockito.ArgumentMatchers.any(Object[].class))).thenThrow(new org.springframework.dao.DataAccessResourceFailureException("internal"));
        mvc.perform(get("/api/reports/compliance").with(authentication(authenticationFor("REPORTING_OFFICER")))).andExpect(status().isInternalServerError()).andExpect(jsonPath("$.error").isString());
        mvc.perform(get("/api/reports/administrative-summary").with(authentication(authenticationFor("REPORTING_OFFICER")))).andExpect(status().isForbidden());
        mvc.perform(get("/api/reports/compliance")).andExpect(status().isUnauthorized());
    }
    @Test void summaryHasOnlyOperationalCountsAndNoStore() throws Exception {
        org.mockito.Mockito.when(jdbc.queryForObject(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.eq(String.class))).thenReturn("{\"day\":\"2026-10-26\",\"registeredPatients\":0,\"closedToday\":0,\"scheduledAppointments\":0,\"pendingReferrals\":0,\"availableSlots\":0}");
        mvc.perform(get("/api/reports/administrative-summary").with(authentication(authenticationFor("ADMINISTRATIVE")))).andExpect(status().isOk()).andExpect(jsonPath("$.data.closedToday").value(0)).andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.header().string("Cache-Control","no-store, private"));
    }
    private static UsernamePasswordAuthenticationToken authenticationFor(String role) {
        SessionPrincipal principal = new SessionPrincipal(UUID.randomUUID(), "reports@example.invalid", "Reportes", List.of(role));
        return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
    }
}

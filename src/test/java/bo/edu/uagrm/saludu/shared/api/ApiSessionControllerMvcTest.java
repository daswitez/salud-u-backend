package bo.edu.uagrm.saludu.shared.api;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthEndpoint;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import jakarta.servlet.http.Cookie;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import static org.mockito.BDDMockito.given;

@WebMvcTest(controllers = {ApiSessionController.class, BackendHealthController.class})
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class ApiSessionControllerMvcTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper objectMapper;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    @MockBean HealthEndpoint healthEndpoint;

    @Test
    void backendHealthIsPublicAndDoesNotExposeSupabase() throws Exception {
        given(healthEndpoint.health()).willReturn(Health.up().build());

        mvc.perform(get("/api/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.service").value("backend"))
            .andExpect(jsonPath("$.status").value("UP"))
            .andExpect(jsonPath("$.error").value(org.hamcrest.Matchers.nullValue()));
    }

    @Test
    void backendHealthReportsUnavailableDependencyWithoutInternalDetails() throws Exception {
        given(healthEndpoint.health()).willReturn(Health.down().build());

        mvc.perform(get("/api/health"))
            .andExpect(status().isServiceUnavailable())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.service").value("backend"))
            .andExpect(jsonPath("$.error").value("backend_unavailable"));
    }

    @Test
    void databaseOutageWhileResolvingSessionIsUnavailableNotUnauthenticated() throws Exception {
        given(sessionCookieService.read(org.mockito.ArgumentMatchers.any())).willReturn(java.util.Optional.of("token"));
        given(authenticationService.resolve("token")).willThrow(new org.springframework.dao.DataAccessResourceFailureException("PostgreSQL detenido"));

        mvc.perform(get("/api/medical/appointments"))
            .andExpect(status().isServiceUnavailable())
            .andExpect(header().string("X-Error-Code", "SERVICE_UNAVAILABLE"))
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value(org.hamcrest.Matchers.startsWith("El servicio no está disponible")));
        mvc.perform(get("/api/v1/me"))
            .andExpect(status().isServiceUnavailable())
            .andExpect(jsonPath("$.error.code").value("SERVICE_UNAVAILABLE"));
        org.mockito.Mockito.verify(sessionCookieService, org.mockito.Mockito.never()).clear(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void legacyClinicalRoutesKeepStringAuthenticationErrors() throws Exception {
        mvc.perform(get("/api/medical/appointments"))
            .andExpect(status().isUnauthorized())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("unauthenticated"));
    }

    @Test
    void genericErrorsUseTextOnlyForCompatibilityRoutes() {
        ApiExceptionHandler errors = new ApiExceptionHandler();

        ResponseEntity<?> legacy = errors.invalidRequest(new IllegalArgumentException(), new MockHttpServletRequest("POST", "/api/medical/encounters/x/finalize"));
        LegacyAvailabilityResponse<?> legacyBody = assertInstanceOf(LegacyAvailabilityResponse.class, legacy.getBody());
        assertEquals("La solicitud no tiene un formato válido.", legacyBody.error());

        ResponseEntity<?> versioned = errors.invalidRequest(new IllegalArgumentException(), new MockHttpServletRequest("POST", "/api/v1/profile"));
        ApiEnvelope<?> versionedBody = assertInstanceOf(ApiEnvelope.class, versioned.getBody());
        assertEquals("INVALID_REQUEST", versionedBody.error().code());
    }

    @Test
    void csrfTokenCreatesReusableSessionAndAllowsLogout() throws Exception {
        MvcResult csrfResult = mvc.perform(get("/api/v1/security/csrf"))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(header().exists(RequestIdFilter.HEADER))
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.headerName").value("X-CSRF-TOKEN"))
            .andReturn();

        JsonNode payload = objectMapper.readTree(csrfResult.getResponse().getContentAsByteArray());
        String token = payload.at("/data/token").asText();
        Cookie csrfCookie = csrfResult.getResponse().getCookie("SALUD_U_CSRF");

        mvc.perform(post("/api/v1/session/logout").cookie(csrfCookie).header("X-CSRF-TOKEN", token))
            .andExpect(status().isNoContent());
    }

    @Test
    void logoutWithoutCsrfReturnsStandardError() throws Exception {
        mvc.perform(post("/api/v1/session/logout"))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.data").doesNotExist())
            .andExpect(jsonPath("$.error.code").value("CSRF_INVALID"))
            .andExpect(jsonPath("$.error.requestId").isNotEmpty());
    }

    @Test
    void sessionProbeRejectsAnonymousRequestsWithStandardError() throws Exception {
        mvc.perform(get("/api/v1/session"))
            .andExpect(status().isUnauthorized())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error.code").value("UNAUTHENTICATED"));
    }

    @Test
    @WithMockUser(username = "qa-administrative", roles = "ADMINISTRATIVE")
    void sessionProbeReturnsAuthenticatedRoleWithoutCreatingDemoUser() throws Exception {
        mvc.perform(get("/api/v1/session"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.subject").value("qa-administrative"))
            .andExpect(jsonPath("$.data.authorities[0]").value("ROLE_ADMINISTRATIVE"));
    }
}

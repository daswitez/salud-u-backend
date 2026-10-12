package bo.edu.uagrm.saludu.shared.api;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.mock.web.MockHttpSession;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

@WebMvcTest(controllers = ApiSessionController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class ApiSessionControllerMvcTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper objectMapper;

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
        MockHttpSession session = (MockHttpSession) csrfResult.getRequest().getSession(false);

        mvc.perform(post("/api/v1/session/logout").session(session).header("X-CSRF-TOKEN", token))
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

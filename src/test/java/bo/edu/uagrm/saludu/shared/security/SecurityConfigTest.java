package bo.edu.uagrm.saludu.shared.security;

import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = SecurityConfigTest.ProbeController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, SecurityConfigTest.ProbeController.class})
class SecurityConfigTest {
    @Autowired MockMvc mvc;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void healthIsPublic() throws Exception {
        mvc.perform(get("/actuator/health")).andExpect(status().isOk());
    }

    @Test
    void anonymousBusinessRequestRequiresAuthentication() throws Exception {
        mvc.perform(get("/api/patients")).andExpect(status().isUnauthorized());
    }

    @Test
    void authenticatedBusinessRequestIsStillDenied() throws Exception {
        mvc.perform(get("/api/private").with(user("test")))
                .andExpect(status().isForbidden());
    }

    @Test
    void writesRequireCsrfAndRemainDeniedWithToken() throws Exception {
        mvc.perform(post("/api/private").with(user("test")))
                .andExpect(status().isForbidden())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.header().string("X-Error-Code","CSRF_INVALID"))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.error").value("forbidden"));
        mvc.perform(post("/api/private").with(user("test")).with(csrf()))
                .andExpect(status().isForbidden())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.header().string("X-Error-Code","FORBIDDEN"));
    }

    @RestController
    static class ProbeController {
        @GetMapping("/actuator/health")
        String health() { return "ok"; }
    }
}

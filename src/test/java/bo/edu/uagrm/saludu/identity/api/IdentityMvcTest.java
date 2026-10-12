package bo.edu.uagrm.saludu.identity.api;

import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.identity.application.AuthenticatedSession;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(controllers = {AuthController.class, LegacyMeController.class})
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class, SessionCookieService.class})
class IdentityMvcTest {
    @Autowired MockMvc mvc;
    @MockBean AuthenticationService authenticationService;

    @Test
    void loginRequiresCsrfBeforeCredentialsAreRead() throws Exception {
        mvc.perform(post("/api/v1/auth/login")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"email\":\"student@example.invalid\",\"password\":\"secret\"}"))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.error.code").value("CSRF_INVALID"));
    }

    @Test
    void loginSetsHttpOnlySecureSessionCookieAndReturnsVersionedContract() throws Exception {
        SessionPrincipal principal = new SessionPrincipal(
            UUID.fromString("00000000-0000-4000-8000-000000000001"),
            "student@example.invalid",
            "Estudiante Sintético",
            List.of("STUDENT")
        );
        when(authenticationService.login("student@example.invalid", "secret"))
            .thenReturn(new AuthenticatedSession(principal, "server-only-token"));

        mvc.perform(post("/api/v1/auth/login")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"email\":\"student@example.invalid\",\"password\":\"secret\"}"))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(header().string("Set-Cookie", org.hamcrest.Matchers.allOf(
                org.hamcrest.Matchers.containsString("SALUD_U_SESSION=server-only-token"),
                org.hamcrest.Matchers.containsString("HttpOnly"),
                org.hamcrest.Matchers.containsString("Secure"),
                org.hamcrest.Matchers.containsString("SameSite=Lax")
            )))
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.user.id").value("00000000-0000-4000-8000-000000000001"))
            .andExpect(jsonPath("$.data.user.role").value("estudiante"))
            .andExpect(jsonPath("$.data.user.clinicalRole").value("STUDENT"));

        verify(authenticationService).login("student@example.invalid", "secret");
    }

    @Test
    void invalidCredentialsDoNotRevealWhetherAnAccountExists() throws Exception {
        when(authenticationService.login("student@example.invalid", "wrong")).thenThrow(new InvalidCredentialsException());

        mvc.perform(post("/api/v1/auth/login")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"email\":\"student@example.invalid\",\"password\":\"wrong\"}"))
            .andExpect(status().isUnauthorized())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error.code").value("INVALID_CREDENTIALS"));
    }

    @Test
    void legacyMeKeepsItsFiveUserFields() throws Exception {
        SessionPrincipal principal = new SessionPrincipal(
            UUID.fromString("00000000-0000-4000-8000-000000000001"),
            "student@example.invalid",
            "Estudiante Sintético",
            List.of("STUDENT")
        );
        var authentication = new UsernamePasswordAuthenticationToken(principal, null, List.of());

        mvc.perform(get("/api/me").with(authentication(authentication)))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.user.id").value("00000000-0000-4000-8000-000000000001"))
            .andExpect(jsonPath("$.user.email").value("student@example.invalid"))
            .andExpect(jsonPath("$.user.name").value("Estudiante Sintético"))
            .andExpect(jsonPath("$.user.role").value("estudiante"))
            .andExpect(jsonPath("$.user.clinicalRole").value("STUDENT"));
    }

    @Test
    void anonymousLegacyMeKeepsReferenceUnauthorizedShape() throws Exception {
        mvc.perform(get("/api/me"))
            .andExpect(status().isUnauthorized())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("unauthenticated"));
    }
}

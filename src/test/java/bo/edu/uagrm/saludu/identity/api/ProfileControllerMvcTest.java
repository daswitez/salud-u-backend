package bo.edu.uagrm.saludu.identity.api;

import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.doThrow;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.identity.application.EmailAlreadyUsedException;
import bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException;
import bo.edu.uagrm.saludu.identity.application.ProfileService;
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

@WebMvcTest(ProfileController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class, SessionCookieService.class})
class ProfileControllerMvcTest {
    private static final UUID PRINCIPAL_ID = UUID.fromString("00000000-0000-4000-8000-000000000001");

    @Autowired MockMvc mvc;
    @MockBean ProfileService profileService;

    @Test
    void profileUpdateRequiresCsrf() throws Exception {
        mvc.perform(patch("/api/v1/profile")
                .with(authentication(authentication()))
                .contentType(MediaType.APPLICATION_JSON)
                .content(profileBody()))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.error.code").value("CSRF_INVALID"));
    }

    @Test
    void profileUpdateRevokesCookieWithoutReturningCredentials() throws Exception {
        mvc.perform(patch("/api/v1/profile")
                .with(authentication(authentication()))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content(profileBody()))
            .andExpect(status().isNoContent())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(header().string("Set-Cookie", org.hamcrest.Matchers.allOf(
                org.hamcrest.Matchers.containsString("SALUD_U_SESSION="),
                org.hamcrest.Matchers.containsString("Max-Age=0"),
                org.hamcrest.Matchers.containsString("HttpOnly"),
                org.hamcrest.Matchers.containsString("Secure")
            )));
        verify(profileService).updateProfile(principal(), "Nuevo nombre", "new@example.invalid", "current-password");
    }

    @Test
    void wrongCurrentPasswordIsRejected() throws Exception {
        doThrow(new InvalidCredentialsException()).when(profileService)
            .changePassword(principal(), "wrong-password", "new-password-123");

        mvc.perform(post("/api/v1/profile/password")
                .with(authentication(authentication()))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"currentPassword\":\"wrong-password\",\"newPassword\":\"new-password-123\"}"))
            .andExpect(status().isUnauthorized())
            .andExpect(jsonPath("$.error.code").value("INVALID_CREDENTIALS"));
    }

    @Test
    void existingEmailIsRejectedWithoutCookieMutation() throws Exception {
        doThrow(new EmailAlreadyUsedException()).when(profileService)
            .updateProfile(principal(), "Nuevo nombre", "used@example.invalid", "current-password");

        mvc.perform(patch("/api/v1/profile")
                .with(authentication(authentication()))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"displayName\":\"Nuevo nombre\",\"email\":\"used@example.invalid\",\"currentPassword\":\"current-password\"}"))
            .andExpect(status().isConflict())
            .andExpect(jsonPath("$.error.code").value("EMAIL_ALREADY_USED"));
    }

    @Test
    void passwordChangeRevokesCookie() throws Exception {
        mvc.perform(post("/api/v1/profile/password")
                .with(authentication(authentication()))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"currentPassword\":\"current-password\",\"newPassword\":\"new-password-123\"}"))
            .andExpect(status().isNoContent())
            .andExpect(header().string("Set-Cookie", org.hamcrest.Matchers.containsString("Max-Age=0")));
        verify(profileService).changePassword(principal(), "current-password", "new-password-123");
    }

    private static String profileBody() {
        return "{\"displayName\":\"Nuevo nombre\",\"email\":\"new@example.invalid\",\"currentPassword\":\"current-password\"}";
    }

    private static SessionPrincipal principal() {
        return new SessionPrincipal(PRINCIPAL_ID, "student@example.invalid", "Estudiante", List.of("STUDENT"));
    }

    private static UsernamePasswordAuthenticationToken authentication() {
        return new UsernamePasswordAuthenticationToken(principal(), null, List.of());
    }
}

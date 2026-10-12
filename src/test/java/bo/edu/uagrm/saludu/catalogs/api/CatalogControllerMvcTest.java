package bo.edu.uagrm.saludu.catalogs.api;

import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.catalogs.application.CatalogItem;
import bo.edu.uagrm.saludu.catalogs.application.CatalogKind;
import bo.edu.uagrm.saludu.catalogs.application.CatalogService;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
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
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(controllers = {CatalogController.class, AdministrationController.class})
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class CatalogControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean CatalogService catalogService;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void careersRemainPublicAndKeepLegacyOrderingShape() throws Exception {
        when(catalogService.list(CatalogKind.CAREER, null)).thenReturn(List.of(
            new CatalogItem(UUID.fromString("00000000-0000-4000-8000-000000000004"), "SYN", "Carrera Sintética")
        ));
        mvc.perform(get("/api/careers"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data[0].code").value("SYN"))
            .andExpect(jsonPath("$.data[0].name").value("Carrera Sintética"));
    }

    @Test
    void studentCannotReadSpecialtiesAndReceivesLegacyForbiddenShape() throws Exception {
        mvc.perform(get("/api/specialties").with(authentication(token("student@example.invalid", "STUDENT"))))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("forbidden"));
    }

    @Test
    void specialistOnlyReceivesCurrentSpecialties() throws Exception {
        SessionPrincipal specialist = principal("specialist@example.invalid", "SPECIALIST");
        when(catalogService.mySpecialties(specialist)).thenReturn(List.of(
            new CatalogItem(UUID.fromString("00000000-0000-4000-8000-000000000005"), "GYNECOLOGY", "Especialidad Sintética")
        ));
        mvc.perform(get("/api/my-specialties").with(authentication(token(specialist, "SPECIALIST"))))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data[0].code").value("GYNECOLOGY"));
    }

    @Test
    void onlyAdministrativeRoleCanWriteCatalogsAndCsrfIsRequired() throws Exception {
        String body = "{\"code\":\"NUTRITION\",\"name\":\"Nutrición\",\"active\":true}";
        mvc.perform(post("/api/v1/admin/catalogs/SPECIALTY")
                .with(authentication(token("student@example.invalid", "STUDENT")))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(body))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.error.code").value("FORBIDDEN"));

        SessionPrincipal administrator = principal("admin@example.invalid", "ADMINISTRATIVE");
        UUID specialtyId = UUID.fromString("00000000-0000-4000-8000-000000000006");
        when(catalogService.saveCatalog(administrator, CatalogKind.SPECIALTY, null, "NUTRITION", "Nutrición", true)).thenReturn(specialtyId);
        mvc.perform(post("/api/v1/admin/catalogs/SPECIALTY")
                .with(authentication(token(administrator, "ADMINISTRATIVE")))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(body))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.id").value(specialtyId.toString()));
        verify(catalogService).saveCatalog(administrator, CatalogKind.SPECIALTY, null, "NUTRITION", "Nutrición", true);
    }

    private static SessionPrincipal principal(String email, String role) {
        return new SessionPrincipal(UUID.nameUUIDFromBytes(email.getBytes()), email, "Usuario de prueba", List.of(role));
    }

    private static UsernamePasswordAuthenticationToken token(String email, String role) {
        return token(principal(email, role), role);
    }

    private static UsernamePasswordAuthenticationToken token(SessionPrincipal principal, String role) {
        return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
    }
}

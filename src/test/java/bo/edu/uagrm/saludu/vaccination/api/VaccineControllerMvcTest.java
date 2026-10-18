package bo.edu.uagrm.saludu.vaccination.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
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
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(VaccineController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class VaccineControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void administrativeActorCreatesVaccineSchedule() throws Exception {
        UUID id = UUID.randomUUID();
        when(jdbc.queryForObject(eq("select salud_u.guardar_vacuna_y_esquema(?, ?, ?, ?, cast(? as jsonb))"), eq(UUID.class), any(), any(), any(), any(), any())).thenReturn(id);
        mvc.perform(post("/api/vaccines").with(authentication(authenticationFor("ADMINISTRATIVE"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(validBody()))
            .andExpect(status().isCreated()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data.id").value(id.toString()));
    }

    @Test
    void nonAdministrativeActorCannotWriteVaccineCatalog() throws Exception {
        mvc.perform(post("/api/vaccines").with(authentication(authenticationFor("REVIEW_DOCTOR"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(validBody()))
            .andExpect(status().isForbidden());
    }

    @Test
    void rejectsIncompleteScheduleBeforePersistence() throws Exception {
        mvc.perform(post("/api/vaccines").with(authentication(authenticationFor("ADMINISTRATIVE"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"code\":\"VX\",\"name\":\"Vacuna\",\"active\":true}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.ok").value(false));
    }

    private static String validBody() { return "{\"code\":\"HEP-B\",\"name\":\"Hepatitis B\",\"active\":true,\"doses\":[{\"doseNumber\":1,\"minimumIntervalDays\":0},{\"doseNumber\":2,\"minimumIntervalDays\":28}]}"; }
    private static UsernamePasswordAuthenticationToken authenticationFor(String role) { SessionPrincipal principal = new SessionPrincipal(UUID.randomUUID(), "vaccine@example.invalid", "Vacunas", List.of(role)); return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role))); }
}

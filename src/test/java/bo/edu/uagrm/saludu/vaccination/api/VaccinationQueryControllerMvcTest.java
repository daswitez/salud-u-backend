package bo.edu.uagrm.saludu.vaccination.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
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

@WebMvcTest(VaccinationQueryController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class VaccinationQueryControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void studentCanReadOwnVaccinationCardContract() throws Exception {
        UUID patient = UUID.randomUUID();
        when(jdbc.queryForObject(eq("select salud_u.obtener_carnet_vacunacion(?)::text"), eq(String.class), any())).thenReturn("{\"patientId\":\"" + patient + "\",\"carnet\":\"12345\",\"vaccines\":[]}");
        mvc.perform(get("/api/vaccination-card").with(authentication(authenticationFor("STUDENT"))))
            .andExpect(status().isOk()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data.carnet").value("12345")).andExpect(jsonPath("$.data.vaccines").isArray());
    }

    @Test
    void unauthorizedRolesCannotReadCardOrCoverage() throws Exception {
        mvc.perform(get("/api/vaccination-card").with(authentication(authenticationFor("REPORTING_OFFICER")))).andExpect(status().isForbidden());
        mvc.perform(get("/api/reports/vaccination-coverage").with(authentication(authenticationFor("STUDENT")))).andExpect(status().isForbidden());
    }

    private static UsernamePasswordAuthenticationToken authenticationFor(String role) { SessionPrincipal principal = new SessionPrincipal(UUID.randomUUID(), "vaccination-query@example.invalid", "Consulta vacunas", List.of(role)); return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role))); }
}

package bo.edu.uagrm.saludu.agenda.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
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
import java.util.Map;
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

@WebMvcTest(MedicalAppointmentController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class MedicalAppointmentControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbcTemplate;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuditWriter auditWriter;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void createsDraftEncounterWith201() throws Exception {
        UUID appointmentId = UUID.fromString("00000000-0000-4000-8000-000000000091");
        UUID encounterId = UUID.fromString("00000000-0000-4000-8000-000000000092");
        when(jdbcTemplate.queryForMap(eq("select * from salud_u.abrir_encuentro_borrador(?)"), eq(appointmentId)))
            .thenReturn(Map.of("id_encuentro", encounterId, "estado", "DRAFT", "creado", true));

        mvc.perform(post("/api/medical/appointments/{id}/start", appointmentId).with(authentication(doctorAuthentication())).with(csrf()))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.encounterId").value(encounterId.toString()))
            .andExpect(jsonPath("$.data.status").value("DRAFT"));
    }

    @Test
    void recoversExistingDraftWith200() throws Exception {
        UUID appointmentId = UUID.fromString("00000000-0000-4000-8000-000000000091");
        UUID encounterId = UUID.fromString("00000000-0000-4000-8000-000000000092");
        when(jdbcTemplate.queryForMap(eq("select * from salud_u.abrir_encuentro_borrador(?)"), eq(appointmentId)))
            .thenReturn(Map.of("id_encuentro", encounterId, "estado", "DRAFT", "creado", false));

        mvc.perform(post("/api/medical/appointments/{id}/start", appointmentId).with(authentication(doctorAuthentication())).with(csrf()))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.encounterId").value(encounterId.toString()));
    }

    private static UsernamePasswordAuthenticationToken doctorAuthentication() {
        SessionPrincipal doctor = new SessionPrincipal(UUID.fromString("00000000-0000-4000-8000-000000000090"), "doctor@example.invalid", "Médico", List.of("REVIEW_DOCTOR"));
        return new UsernamePasswordAuthenticationToken(doctor, null, List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));
    }
}

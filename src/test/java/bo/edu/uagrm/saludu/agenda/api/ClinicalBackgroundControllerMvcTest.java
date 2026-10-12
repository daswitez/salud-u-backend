package bo.edu.uagrm.saludu.agenda.api;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import com.fasterxml.jackson.databind.ObjectMapper;
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

@WebMvcTest(ClinicalBackgroundController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class ClinicalBackgroundControllerMvcTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper objectMapper;
    @MockBean JdbcTemplate jdbcTemplate;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuditWriter auditWriter;

    @Test
    void changeReasonIsRequiredBeforeAnyPersistence() throws Exception {
        UUID patientId = UUID.fromString("00000000-0000-4000-8000-000000000031");
        mvc.perform(patch("/api/medical/patients/{id}/clinical-background", patientId).with(authentication(doctorAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(objectMapper.writeValueAsString(java.util.Map.of("data", java.util.Map.of("schemaVersion", 1), "expectedVersion", 0))))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("Indica datos válidos y el motivo de actualización."));
    }

    private static UsernamePasswordAuthenticationToken doctorAuthentication() {
        SessionPrincipal doctor = new SessionPrincipal(UUID.fromString("00000000-0000-4000-8000-000000000030"), "doctor@example.invalid", "Médico", List.of("REVIEW_DOCTOR"));
        return new UsernamePasswordAuthenticationToken(doctor, null, List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));
    }
}

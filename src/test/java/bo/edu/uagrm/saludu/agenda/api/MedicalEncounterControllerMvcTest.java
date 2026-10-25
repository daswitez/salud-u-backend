package bo.edu.uagrm.saludu.agenda.api;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;

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

@WebMvcTest(MedicalEncounterController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class MedicalEncounterControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbcTemplate;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuditWriter auditWriter;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void reviewCompletionRequiresStructuredRecordAndClinicalSummary() throws Exception {
        mvc.perform(post("/api/medical/encounters/{id}/finalize", UUID.fromString("00000000-0000-4000-8000-000000000101"))
                .with(authentication(reviewDoctorAuthentication())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("El motivo de consulta, la evaluación y la ficha de revisión son obligatorios."));
    }

    @Test
    void onlyClinicalDoctorsCanFinalizeAnEncounter() throws Exception {
        SessionPrincipal specialist = new SessionPrincipal(UUID.randomUUID(), "administrator@example.invalid", "Administrativo", List.of("ADMINISTRATIVE"));
        mvc.perform(post("/api/medical/encounters/{id}/finalize", UUID.randomUUID())
                .with(authentication(new UsernamePasswordAuthenticationToken(specialist, null, List.of(new SimpleGrantedAuthority("ROLE_ADMINISTRATIVE"))))).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content("{}"))
            .andExpect(status().isForbidden());
    }

    @Test
    void reviewCompletionReturnsCharacterizedRpcContract() throws Exception {
        UUID encounterId = UUID.randomUUID();
        when(jdbcTemplate.queryForObject(anyString(), eq(String.class), any(Object[].class))).thenReturn(
            "{\"encounterId\":\"" + encounterId + "\",\"referralId\":null,\"reviewHistoryVersion\":1}"
        );
        mvc.perform(post("/api/medical/encounters/{id}/finalize", encounterId)
                .with(authentication(reviewDoctorAuthentication())).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                .content("{\"chiefComplaint\":\"Control\",\"assessment\":\"Estable\",\"reviewHistory\":{}}"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.encounterId").value(encounterId.toString()))
            .andExpect(jsonPath("$.data.referralId").doesNotExist())
            .andExpect(jsonPath("$.data.reviewHistoryVersion").value(1));
    }

    @Test
    void referralRequiresReasonAndSummary() throws Exception {
        mvc.perform(post("/api/medical/encounters/{id}/finalize", UUID.randomUUID())
                .with(authentication(reviewDoctorAuthentication())).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                .content("{\"chiefComplaint\":\"Control\",\"assessment\":\"Estable\",\"reviewHistory\":{},\"referralSpecialtyId\":\"" + UUID.randomUUID() + "\"}"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("Completa el motivo y el resumen para el especialista."));
    }

    private static UsernamePasswordAuthenticationToken reviewDoctorAuthentication() {
        SessionPrincipal doctor = new SessionPrincipal(UUID.fromString("00000000-0000-4000-8000-000000000100"), "doctor@example.invalid", "Médico", List.of("REVIEW_DOCTOR"));
        return new UsernamePasswordAuthenticationToken(doctor, null, List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));
    }

    @Test void ownContextIsReturnedAndForeignContextIsHidden() throws Exception {
        UUID id=UUID.randomUUID();
        when(jdbcTemplate.queryForObject(eq("select salud_u.obtener_contexto_encuentro_propio(?)::text"),eq(String.class),eq(id)))
            .thenReturn("{\"encounter\":{\"status\":\"DRAFT\"},\"diagnoses\":[],\"documents\":[],\"measurements\":[]}")
            .thenThrow(new org.springframework.dao.DataIntegrityViolationException("ENCUENTRO_AJENO_O_INEXISTENTE"));
        mvc.perform(get("/api/medical/encounters/{id}",id).with(authentication(reviewDoctorAuthentication())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.encounter.status").value("DRAFT")).andExpect(jsonPath("$.data.diagnoses").isEmpty());
        mvc.perform(get("/api/medical/encounters/{id}",id).with(authentication(reviewDoctorAuthentication())))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").isString());
    }

    @Test void closedReviewReturnsConflictWithoutSuccess() throws Exception {
        when(jdbcTemplate.queryForObject(anyString(),eq(String.class),any(Object[].class)))
            .thenThrow(new org.springframework.dao.DataIntegrityViolationException("ENCUENTRO_CERRADO"));
        mvc.perform(post("/api/medical/encounters/{id}/finalize",UUID.randomUUID()).with(authentication(reviewDoctorAuthentication())).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"chiefComplaint\":\"Control\",\"assessment\":\"Estable\",\"reviewHistory\":{}}"))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.ok").value(false));
    }

    @Test void characterizedT01PayloadWithOmittedHistoryUsesNormalizedEmptyRecord() throws Exception {
        UUID id=UUID.randomUUID();
        when(jdbcTemplate.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenAnswer(invocation->{
            Object[] args=(Object[])invocation.getRawArguments()[2];
            var history=new com.fasterxml.jackson.databind.ObjectMapper().readTree((String)args[7]);
            org.junit.jupiter.api.Assertions.assertEquals(1,history.path("versionEsquema").asInt());
            org.junit.jupiter.api.Assertions.assertTrue(history.path("signosVitales").path("peso").isNull());
            return "{\"encounterId\":\""+id+"\",\"referralId\":null,\"reviewHistoryVersion\":1}";
        });
        mvc.perform(post("/api/medical/encounters/{id}/finalize",id).with(authentication(reviewDoctorAuthentication())).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"chiefComplaint\":\"Caso sintético\",\"assessment\":\"Evaluación sintética\",\"specialtyHistory\":{\"specialtyCode\":\"GYNECOLOGY\"}}"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.referralId").hasJsonPath()).andExpect(jsonPath("$.data.reviewHistoryVersion").value(1));
    }
}

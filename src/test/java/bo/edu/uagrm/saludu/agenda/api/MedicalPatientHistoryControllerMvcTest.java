package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.*;
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
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(MedicalPatientHistoryController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class MedicalPatientHistoryControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken doctor(String role){var p=new SessionPrincipal(UUID.randomUUID(),"doctor@example.invalid","Médico",List.of(role));return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_"+role)));}
    @Test void authorizedEmptyHistoryKeepsContractNullAndNoStore() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{\"patient\":{\"phone\":null},\"intake\":null,\"clinicalBackground\":null,\"encounters\":[],\"diagnoses\":[],\"documents\":[],\"appointments\":[],\"referrals\":[]}");
        for(String role:List.of("REVIEW_DOCTOR","SPECIALIST"))mvc.perform(get("/api/medical/patients/{id}",UUID.randomUUID()).with(authentication(doctor(role))))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store, private")).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data.encounters").isEmpty()).andExpect(jsonPath("$.data.clinicalBackground").doesNotExist());
    }
    @Test void foreignIsReference404AndOtherRolesCannotRead() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataIntegrityViolationException("PACIENTE_SIN_ACCESO_CLINICO"));
        mvc.perform(get("/api/medical/patients/{id}",UUID.randomUUID()).with(authentication(doctor("REVIEW_DOCTOR")))).andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("No tienes acceso clínico a este paciente."));
        for(String role:List.of("ADMINISTRATIVE","STUDENT"))mvc.perform(get("/api/medical/patients/{id}",UUID.randomUUID()).with(user("other").roles(role))).andExpect(status().isForbidden());
        mvc.perform(get("/api/medical/patients/{id}",UUID.randomUUID())).andExpect(status().isUnauthorized());
    }
    @Test void databaseFailureIsRecoverableWithoutDetails() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataAccessResourceFailureException("Detalles internos"));
        mvc.perform(get("/api/medical/patients/{id}",UUID.randomUUID()).with(authentication(doctor("SPECIALIST")))).andExpect(status().isInternalServerError()).andExpect(jsonPath("$.error").value("No se pudo consultar la historia clínica. Reintenta la consulta."));
    }
}

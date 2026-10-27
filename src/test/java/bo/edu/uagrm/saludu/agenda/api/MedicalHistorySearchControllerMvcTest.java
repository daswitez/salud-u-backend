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
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(MedicalHistorySearchController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class MedicalHistorySearchControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken doctor(){var p=new SessionPrincipal(UUID.randomUUID(),"doctor@example.invalid","Médico",List.of("REVIEW_DOCTOR"));return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));}
    @Test void nullsAndEmptyAreReturnedWithoutMapOfFailure() throws Exception {
        UUID id=UUID.randomUUID();
        when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(List.of(new MedicalHistorySearchController.Result(id,null,"INITIAL","CLOSED",null,null,null))).thenReturn(List.of());
        mvc.perform(get("/api/medical/patients/{id}/search",UUID.randomUUID()).with(authentication(doctor())).param("q","evaluacion"))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store, private")).andExpect(jsonPath("$.data[0].id").value(id.toString())).andExpect(jsonPath("$.data[0].specialty").doesNotExist());
        mvc.perform(get("/api/medical/patients/{id}/search",UUID.randomUUID()).with(authentication(doctor())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data").isEmpty());
    }
    @Test void invalidDatesAndLongTextReturn400() throws Exception {
        for(String[] pair:new String[][]{{"2026-10-25","2026-10-24"},{"no-fecha","2026-10-24"}})
            mvc.perform(get("/api/medical/patients/{id}/search",UUID.randomUUID()).with(authentication(doctor())).param("from",pair[0]).param("to",pair[1])).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        mvc.perform(get("/api/medical/patients/{id}/search",UUID.randomUUID()).with(authentication(doctor())).param("q","a".repeat(201))).andExpect(status().isBadRequest());
    }
    @Test void foreignAndRolesCannotSearch() throws Exception {
        when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataIntegrityViolationException("PACIENTE_SIN_ACCESO_CLINICO"));
        mvc.perform(get("/api/medical/patients/{id}/search",UUID.randomUUID()).with(authentication(doctor()))).andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("No tienes acceso clínico a este paciente."));
        for(String role:List.of("ADMINISTRATIVE","STUDENT"))mvc.perform(get("/api/medical/patients/{id}/search",UUID.randomUUID()).with(user("other").roles(role))).andExpect(status().isForbidden());
        mvc.perform(get("/api/medical/patients/{id}/search",UUID.randomUUID())).andExpect(status().isUnauthorized());
    }
}

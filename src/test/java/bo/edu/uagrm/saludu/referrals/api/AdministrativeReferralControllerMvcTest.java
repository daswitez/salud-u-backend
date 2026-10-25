package bo.edu.uagrm.saludu.referrals.api;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.*;
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
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(ReferralController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class AdministrativeReferralControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken admin(){
        var p=new SessionPrincipal(UUID.randomUUID(),"admin@example.invalid","Administración",List.of("ADMINISTRATIVE"));
        return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_ADMINISTRATIVE")));
    }
    @Test void inboxKeepsPendingNullsAndAssignedHistory() throws Exception {
        Map<String,Object> item=new java.util.LinkedHashMap<>();
        item.put("id",UUID.randomUUID());item.put("status","PENDING_ASSIGNMENT");item.put("reason","Motivo");item.put("assigned_staff_name",null);item.put("appointment_id",null);item.put("scheduled_for",null);
        when(jdbc.query(anyString(),any(RowMapper.class))).thenReturn(List.of(item));
        mvc.perform(get("/api/administrative/referrals").with(authentication(admin())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data[0].status").value("PENDING_ASSIGNMENT"))
            .andExpect(jsonPath("$.data[0].assigned_staff_name").hasJsonPath()).andExpect(jsonPath("$.data[0].appointment_id").hasJsonPath());
        item.put("status","ASSIGNED");item.put("assigned_staff_name","Especialista");item.put("appointment_id",UUID.randomUUID());
        mvc.perform(get("/api/administrative/referrals").with(authentication(admin())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data[0].status").value("ASSIGNED"));
    }
    @Test void patientOptionsAndEmptyInboxKeepListContract() throws Exception {
        when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(List.of(Map.of("id",UUID.randomUUID(),"specialty_id",UUID.randomUUID(),"specialty_name","Área","status","ASSIGNED")));
        mvc.perform(get("/api/patients/{id}/referrals",UUID.randomUUID()).with(authentication(admin())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data[0].specialty_name").value("Área"));
        when(jdbc.query(anyString(),any(RowMapper.class))).thenReturn(List.of());
        mvc.perform(get("/api/administrative/referrals").with(authentication(admin()))).andExpect(status().isOk()).andExpect(jsonPath("$.data").isEmpty());
    }
    @Test void clinicalStudentRolesAndAnonymousCannotReadAdministration() throws Exception {
        for(String role:List.of("REVIEW_DOCTOR","SPECIALIST","STUDENT")){
            mvc.perform(get("/api/administrative/referrals").with(user("other").roles(role))).andExpect(status().isForbidden());
            mvc.perform(get("/api/patients/{id}/referrals",UUID.randomUUID()).with(user("other").roles(role))).andExpect(status().isForbidden());
        }
        mvc.perform(get("/api/administrative/referrals")).andExpect(status().isUnauthorized());
    }
}

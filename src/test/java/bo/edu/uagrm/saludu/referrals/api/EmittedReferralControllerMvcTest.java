package bo.edu.uagrm.saludu.referrals.api;

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
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(EmittedReferralController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class EmittedReferralControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken doctor(){
        var p=new SessionPrincipal(UUID.randomUUID(),"review@example.invalid","Revisión",List.of("REVIEW_DOCTOR"));
        return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));
    }
    @Test void ownEmptyListUsesOkDataContract() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("[]");
        mvc.perform(get("/api/medical/referrals").with(authentication(doctor())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data").isEmpty());
    }
    @Test void detailKeepsPrioritySharedArraysAndNull() throws Exception {
        UUID id=UUID.randomUUID();
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{\"id\":\""+id+"\",\"priority\":\"URGENT\",\"source\":{\"instructions\":null},\"diagnoses\":[],\"documents\":[]}");
        mvc.perform(get("/api/medical/referrals/{id}",id).with(authentication(doctor())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.id").value(id.toString())).andExpect(jsonPath("$.data.priority").value("URGENT"))
            .andExpect(jsonPath("$.data.source.instructions").hasJsonPath()).andExpect(jsonPath("$.data.diagnoses").isEmpty());
    }
    @Test void foreignReferralIsHiddenAndNonReviewRolesAreDenied() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataIntegrityViolationException("DERIVACION_AJENA_O_INEXISTENTE"));
        mvc.perform(get("/api/medical/referrals/{id}",UUID.randomUUID()).with(authentication(doctor())))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").isString()).andExpect(jsonPath("$.data").doesNotExist());
        for(String role:List.of("STUDENT","ADMINISTRATIVE","SPECIALIST"))
            mvc.perform(get("/api/medical/referrals").with(user("other").roles(role))).andExpect(status().isForbidden());
        mvc.perform(get("/api/medical/referrals")).andExpect(status().isUnauthorized());
    }
}

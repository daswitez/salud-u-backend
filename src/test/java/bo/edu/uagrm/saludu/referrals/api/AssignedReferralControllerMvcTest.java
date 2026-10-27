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
import org.springframework.http.MediaType;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest({AssignedReferralController.class,ReferralController.class})
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class AssignedReferralControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken specialist(){var p=new SessionPrincipal(UUID.randomUUID(),"specialist@example.invalid","Especialista",List.of("SPECIALIST"));return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_SPECIALIST")));}
    @Test void ownListKeepsNullAndEmptyState() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("[{\"id\":\""+UUID.randomUUID()+"\",\"followUpText\":null,\"events\":[]}]").thenReturn("[]");
        mvc.perform(get("/api/medical/assigned-referrals").with(authentication(specialist()))).andExpect(status().isOk()).andExpect(jsonPath("$.data[0].followUpText").doesNotExist()).andExpect(jsonPath("$.data[0].events").isEmpty());
        mvc.perform(get("/api/medical/assigned-referrals").with(authentication(specialist()))).andExpect(status().isOk()).andExpect(jsonPath("$.data").isEmpty());
    }
    @Test void foreignAndRolesAreRejected() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("[]");
        mvc.perform(get("/api/medical/assigned-referrals/{id}",UUID.randomUUID()).with(authentication(specialist()))).andExpect(status().isNotFound()).andExpect(jsonPath("$.error").isString());
        for(String role:List.of("REVIEW_DOCTOR","ADMINISTRATIVE","STUDENT"))mvc.perform(get("/api/medical/assigned-referrals").with(user("other").roles(role))).andExpect(status().isForbidden());
        mvc.perform(get("/api/medical/assigned-referrals")).andExpect(status().isUnauthorized());
    }
    @Test void returnValidatesReasonAndFollowUpType() throws Exception {
        for(String body:List.of("{\"action\":\"RETURN\",\"reason\":\" \"}","{\"action\":\"RETURN\",\"reason\":\"Motivo\",\"followUpText\":{}}","{\"action\":\"INVALID\"}"))
            mvc.perform(patch("/api/medical/referrals/{id}",UUID.randomUUID()).with(authentication(specialist())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
    }
    @Test void patchKeepsExactContractAndRejectedTransition() throws Exception {
        UUID id=UUID.randomUUID();
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{\"referralId\":\""+id+"\",\"status\":\"RETURNED\"}")
            .thenThrow(new org.springframework.dao.DataIntegrityViolationException("ATENCION_ESPECIALIZADA_REQUERIDA"))
            .thenThrow(new org.springframework.dao.DataIntegrityViolationException("DERIVACION_AJENA_O_TRANSICION_INVALIDA"));
        var payload="{\"action\":\"RETURN\",\"reason\":\"Motivo\",\"followUpText\":\"Control\"}";
        mvc.perform(patch("/api/medical/referrals/{id}",id).with(authentication(specialist())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isOk()).andExpect(jsonPath("$.data.referralId").value(id.toString())).andExpect(jsonPath("$.data.status").value("RETURNED"));
        mvc.perform(patch("/api/medical/referrals/{id}",id).with(authentication(specialist())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"RESOLVE\"}")).andExpect(status().isConflict());
        mvc.perform(patch("/api/medical/referrals/{id}",id).with(authentication(specialist())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isForbidden());
    }
}

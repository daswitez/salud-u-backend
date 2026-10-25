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
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import org.springframework.http.MediaType;
import bo.edu.uagrm.saludu.agenda.api.AppointmentRequestController;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(AppointmentRequestController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class ReferralSchedulingRequestMvcTest {
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
    private String payload(UUID patient,UUID referral){return "{\"appointmentType\":\"REFERRAL\",\"patientId\":\""+patient+"\",\"referralId\":\""+referral+"\"}";}
    @Test void referralRequestKeeps201IdContract() throws Exception {
        UUID patient=UUID.randomUUID(),referral=UUID.randomUUID(),request=UUID.randomUUID();
        when(jdbc.queryForObject(anyString(),eq(UUID.class),any(Object[].class))).thenReturn(request);
        mvc.perform(post("/api/appointment-requests").with(authentication(admin())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(payload(patient,referral)))
            .andExpect(status().isCreated()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data.id").value(request.toString()));
    }
    @Test void duplicateOrUnavailableReferralIsRecoverable409() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(UUID.class),any(Object[].class)))
            .thenThrow(new org.springframework.dao.DataIntegrityViolationException("SOLICITUD_DERIVACION_PENDIENTE"))
            .thenThrow(new org.springframework.dao.DataIntegrityViolationException("DERIVACION_NO_PROGRAMABLE"));
        for(int i=0;i<2;i++)mvc.perform(post("/api/appointment-requests").with(authentication(admin())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(payload(UUID.randomUUID(),UUID.randomUUID())))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.ok").value(false)).andExpect(jsonPath("$.error").isString());
    }
    @Test void patientIsRequiredAndStudentCannotScheduleReferral() throws Exception {
        mvc.perform(post("/api/appointment-requests").with(authentication(admin())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"appointmentType\":\"REFERRAL\",\"referralId\":\""+UUID.randomUUID()+"\"}")).andExpect(status().isBadRequest());
        var student=new SessionPrincipal(UUID.randomUUID(),"student@example.invalid","Estudiante",List.of("STUDENT"));
        mvc.perform(post("/api/appointment-requests").with(authentication(new UsernamePasswordAuthenticationToken(student,null,List.of(new SimpleGrantedAuthority("ROLE_STUDENT"))))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(payload(UUID.randomUUID(),UUID.randomUUID())))
            .andExpect(status().isForbidden());
    }
}

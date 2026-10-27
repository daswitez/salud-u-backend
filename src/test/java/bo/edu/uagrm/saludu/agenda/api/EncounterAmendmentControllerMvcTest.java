package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.*;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.http.MediaType;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(EncounterAmendmentController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class EncounterAmendmentControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken doctor(){var p=new SessionPrincipal(UUID.randomUUID(),"doctor@example.invalid","Médico",List.of("REVIEW_DOCTOR"));return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));}
    @Test void listHasCapabilityAndOrderedItemsContract() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{\"canAdd\":false,\"items\":[]}");
        mvc.perform(get("/api/medical/encounters/{id}/amendments",UUID.randomUUID()).with(authentication(doctor()))).andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store, private")).andExpect(jsonPath("$.data.canAdd").value(false)).andExpect(jsonPath("$.data.items").isEmpty());
    }
    @Test void creationKeeps200AndFourFields() throws Exception {
        UUID id=UUID.randomUUID(),actor=UUID.randomUUID();
        when(jdbc.queryForObject(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(new EncounterAmendmentController.Created(id,1,java.time.OffsetDateTime.parse("2026-10-25T12:00:00Z"),actor));
        mvc.perform(post("/api/medical/encounters/{id}/amendments",UUID.randomUUID()).with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"Aclaración\",\"content\":\"Corrección\"}"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.id").value(id.toString())).andExpect(jsonPath("$.data.amendmentNo").value(1)).andExpect(jsonPath("$.data.createdBy").value(actor.toString()));
    }
    @Test void invalidAndForbiddenOrConflictAreTextErrors() throws Exception {
        for(String body:List.of("{}","{\"reason\":\" \",\"content\":\"Texto\"}","{\"reason\":\"Motivo\",\"content\":\"Texto\",\"clientRequestId\":\"incorrecto\"}"))
            mvc.perform(post("/api/medical/encounters/{id}/amendments",UUID.randomUUID()).with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        when(jdbc.queryForObject(anyString(),any(RowMapper.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataIntegrityViolationException("SOLICITUD_ADENDA_REUTILIZADA")).thenThrow(new org.springframework.dao.DataIntegrityViolationException("ADENDA_NO_AUTORIZADA"));
        for(int status:new int[]{409,403})mvc.perform(post("/api/medical/encounters/{id}/amendments",UUID.randomUUID()).with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"Motivo\",\"content\":\"Texto\"}")).andExpect(status().is(status)).andExpect(jsonPath("$.error").isString());
    }
    @Test void otherRolesAndAnonymousCannotReadOrWrite() throws Exception {
        for(String role:List.of("ADMINISTRATIVE","STUDENT")){
            mvc.perform(get("/api/medical/encounters/{id}/amendments",UUID.randomUUID()).with(user("other").roles(role))).andExpect(status().isForbidden());
            mvc.perform(post("/api/medical/encounters/{id}/amendments",UUID.randomUUID()).with(user("other").roles(role)).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isForbidden());
        }
        mvc.perform(get("/api/medical/encounters/{id}/amendments",UUID.randomUUID())).andExpect(status().isUnauthorized());
    }
}

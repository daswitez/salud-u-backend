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

@WebMvcTest(ClinicalWordExportController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class ClinicalWordExportControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean bo.edu.uagrm.saludu.agenda.application.ClinicalWordDocument word;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken doctor(){var p=new SessionPrincipal(UUID.randomUUID(),"doctor@example.invalid","Médico",List.of("REVIEW_DOCTOR"));return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));}
    @Test void wordHasBinaryContractAndAuditAfterCompleteGeneration() throws Exception {
        UUID id=UUID.randomUUID();
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{\"encounter\":{\"encounter_type\":\"INITIAL\",\"reviewHistoryVersion\":3},\"amendments\":[]}");
        when(word.render(any(),eq("Atención autorizada"))).thenReturn(new byte[]{80,75,3,4,1});
        mvc.perform(get("/api/medical/encounters/{id}/export.docx",id).param("purpose","Atención autorizada").with(authentication(doctor())))
            .andExpect(status().isOk()).andExpect(content().contentType("application/vnd.openxmlformats-officedocument.wordprocessingml.document"))
            .andExpect(header().string("Cache-Control","no-store, private")).andExpect(header().string("Content-Disposition","attachment; filename=ficha-clinica-"+id+".docx")).andExpect(content().bytes(new byte[]{80,75,3,4,1}));
        org.mockito.Mockito.verify(audit).append(eq("FICHA_WORD_EXPORTADA"),eq("encuentro_clinico"),eq(id),any(),org.mockito.ArgumentMatchers.argThat(d->d.get("finalidad").equals("Atención autorizada")&&d.get("versionFicha").equals(3)));
    }
    @Test void invalidPurposeNeverReadsClinicalData() throws Exception {
        for(String purpose:List.of(" ","x".repeat(501)))mvc.perform(get("/api/medical/encounters/{id}/export.docx",UUID.randomUUID()).param("purpose",purpose).with(authentication(doctor()))).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        org.mockito.Mockito.verifyNoInteractions(jdbc,word,audit);
    }
    @Test void clinicalDenialIsNonExposing404AndFailureIsRecoverable500() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataIntegrityViolationException("FICHA_NO_AUTORIZADA"));
        mvc.perform(get("/api/medical/encounters/{id}/export.docx",UUID.randomUUID()).with(authentication(doctor()))).andExpect(status().isNotFound()).andExpect(jsonPath("$.error").isString());
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{}");when(word.render(any(),anyString())).thenThrow(new java.io.IOException("detalle interno"));
        mvc.perform(get("/api/medical/encounters/{id}/export.docx",UUID.randomUUID()).with(authentication(doctor()))).andExpect(status().isInternalServerError()).andExpect(jsonPath("$.error").value("No se pudo generar el Word. Puedes reintentar la descarga."));
        org.mockito.Mockito.verifyNoInteractions(audit);
    }
    @Test void auditFailureDoesNotPublishWord() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{}");
        when(word.render(any(),anyString())).thenReturn(new byte[]{80,75,3,4});
        org.mockito.Mockito.doThrow(new org.springframework.dao.DataIntegrityViolationException("auditoría no disponible")).when(audit).append(anyString(),anyString(),any(),any(),anyMap());
        mvc.perform(get("/api/medical/encounters/{id}/export.docx",UUID.randomUUID()).with(authentication(doctor()))).andExpect(status().isInternalServerError()).andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON)).andExpect(jsonPath("$.error").isString()).andExpect(header().doesNotExist("Content-Disposition"));
    }
    @Test void otherRolesAndAnonymousCannotExport() throws Exception {
        for(String role:List.of("ADMINISTRATIVE","STUDENT","REPORTING_OFFICER","AUDITOR"))mvc.perform(get("/api/medical/encounters/{id}/export.docx",UUID.randomUUID()).with(user("other").roles(role))).andExpect(status().isForbidden());
        mvc.perform(get("/api/medical/encounters/{id}/export.docx",UUID.randomUUID())).andExpect(status().isUnauthorized());org.mockito.Mockito.verifyNoInteractions(jdbc,word,audit);
    }
}

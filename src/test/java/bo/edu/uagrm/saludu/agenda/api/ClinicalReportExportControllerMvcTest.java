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

@WebMvcTest(ClinicalReportExportController.class)
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class ClinicalReportExportControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportHistory exportHistory;
    @MockBean bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportService exports;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken doctor(){var p=new SessionPrincipal(UUID.randomUUID(),"doctor@example.invalid","Médico",List.of("REVIEW_DOCTOR"));return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));}
    private String body(String format){return "{\"format\":\""+format+"\",\"purpose\":\"Seguimiento\",\"filters\":{},\"columns\":[\"patient_name\"],\"groupBy\":[]}";}
    @Test void formatsHaveCompleteBinaryAndProvenanceHeaders() throws Exception {
        UUID id=UUID.randomUUID();for(String format:List.of("CSV","XLSX","PDF")){
            when(exports.export(any(),any())).thenReturn(new bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportService.File(id,format,2,"a".repeat(64),new byte[]{1,2,3}));
            mvc.perform(post("/api/reports/clinical/export").with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body(format))).andExpect(status().isOk()).andExpect(header().string("X-Export-Id",id.toString())).andExpect(header().string("X-Export-Row-Count","2")).andExpect(header().string("X-Content-SHA256","a".repeat(64))).andExpect(header().string("Cache-Control","no-store, private")).andExpect(header().string("Content-Length","3")).andExpect(content().bytes(new byte[]{1,2,3}));
        }
    }
    @Test void invalidOrClientProvidedRowsCannotReachExportService() throws Exception {
        for(Object invalid:List.of(java.util.Map.of("format","CSV","purpose"," ","filters",java.util.Map.of()),java.util.Map.of("format","CSV","purpose","Uso","filters",List.of(),"columns",List.of()),java.util.Map.of("format","CSV","purpose","Uso","filters",java.util.Map.of(),"rowCount",100),java.util.Map.of("format","CSV","purpose","Uso","filters",java.util.Map.of(),"rows",List.of(java.util.Map.of()))))mvc.perform(post("/api/reports/clinical/export").with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(invalid))).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        org.mockito.Mockito.verifyNoInteractions(exports);
    }
    @Test void errorsNeverPublishAttachmentsAndCsrfProtectsMutation() throws Exception {
        when(exports.export(any(),any())).thenThrow(new java.io.IOException("internal detail"));
        mvc.perform(post("/api/reports/clinical/export").with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body("PDF"))).andExpect(status().isInternalServerError()).andExpect(header().doesNotExist("Content-Disposition")).andExpect(jsonPath("$.error").isString());
        mvc.perform(post("/api/reports/clinical/export").with(authentication(doctor())).contentType(MediaType.APPLICATION_JSON).content(body("PDF"))).andExpect(status().isForbidden());
        for(String role:List.of("STUDENT","AUDITOR"))mvc.perform(post("/api/reports/clinical/export").with(user("other").roles(role)).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body("PDF"))).andExpect(status().isForbidden());
        mvc.perform(post("/api/reports/clinical/export").with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body("PDF"))).andExpect(status().isUnauthorized());
    }
    @Test void generationFailureIsRecordedAfterServiceRollbackWithoutAttachment() throws Exception {
        when(exports.export(any(),any())).thenThrow(new bo.edu.uagrm.saludu.agenda.application.ClinicalReportGenerationFailure(3));
        mvc.perform(post("/api/reports/clinical/export").with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body("PDF"))).andExpect(status().isInternalServerError()).andExpect(header().doesNotExist("Content-Disposition")).andExpect(jsonPath("$.error").isString());
        org.mockito.Mockito.verify(exportHistory).failed(any(),eq(3),any());
    }
    @Test void privateReceiptContractAndNonExposingDenial() throws Exception {
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenReturn("{\"state\":\"COMPLETED\",\"rowCount\":0}");mvc.perform(get("/api/reports/clinical/exports/{id}",UUID.randomUUID()).with(authentication(doctor()))).andExpect(status().isOk()).andExpect(jsonPath("$.data.state").value("COMPLETED")).andExpect(header().string("Cache-Control","no-store, private"));
        when(jdbc.queryForObject(anyString(),eq(String.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataIntegrityViolationException("EXPORTACION_NO_AUTORIZADA"));mvc.perform(get("/api/reports/clinical/exports/{id}",UUID.randomUUID()).with(authentication(doctor()))).andExpect(status().isNotFound()).andExpect(jsonPath("$.error").isString());
    }
}

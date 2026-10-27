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

@WebMvcTest({ClinicalReportController.class,ClinicalReportExportController.class})
@Import({SecurityConfig.class,ApiSecurityErrorWriter.class,RequestIdFilter.class,ApiExceptionHandler.class})
class ClinicalReportControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportHistory exportHistory;
    @MockBean bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportService exports;
    @MockBean DatabaseActorContext actors;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private UsernamePasswordAuthenticationToken doctor(){var p=new SessionPrincipal(UUID.randomUUID(),"doctor@example.invalid","Médico",List.of("REVIEW_DOCTOR"));return new UsernamePasswordAuthenticationToken(p,null,List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));}
    @Test void reportPreservesEnvelopeCanonicalListsEmptyAndPresentation() throws Exception {
        when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(List.of());
        mvc.perform(get("/api/reports/clinical").param("allergies","[\"penicilina\",\"asma\"]").param("columns","[\"patient_name\",\"diagnoses\"]").param("groupBy","[\"specialty\"]").with(authentication(doctor())))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store, private")).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data").isEmpty()).andExpect(jsonPath("$.filters.allergies[0]").value("penicilina")).andExpect(jsonPath("$.filters.search").isEmpty()).andExpect(jsonPath("$.presentation.columns[1]").value("diagnoses")).andExpect(jsonPath("$.presentation.groups").isEmpty());
    }
    @Test void legacyExportLogValidatesBoundsAndReturnsPersistedAuditId() throws Exception {
        UUID id=UUID.randomUUID();when(audit.append(anyString(),anyString(),any(),any(),anyMap())).thenReturn(id);
        for(int count:new int[]{0,10000})mvc.perform(post("/api/reports/clinical").with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"format\":\"CSV\",\"rowCount\":"+count+"}")).andExpect(status().isCreated()).andExpect(jsonPath("$.data.id").value(id.toString()));
        for(String count:List.of("-1","10001","1.5","null"))mvc.perform(post("/api/reports/clinical").with(authentication(doctor())).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"format\":\"CSV\",\"rowCount\":"+count+"}")).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
    }
    @Test void legacyGetDoesNotRequirePresentation() throws Exception {
        when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(List.of());
        mvc.perform(get("/api/reports/clinical").with(authentication(doctor()))).andExpect(status().isOk()).andExpect(jsonPath("$.presentation").doesNotExist()).andExpect(jsonPath("$.filters.positiveHabits").isEmpty());
    }
    @Test void invalidPeriodListsColumnsAndGroupsHaveText400() throws Exception {
        for(String[] pair:List.of(new String[]{"from","2026-02-30"},new String[]{"allergies","[1]"},new String[]{"histories","broken"},new String[]{"positiveHabits","[\"unknown\"]"},new String[]{"columns","[]"},new String[]{"columns","[\"secret\"]"},new String[]{"groupBy","[\"day\",\"month\"]"}))mvc.perform(get("/api/reports/clinical").param(pair[0],pair[1]).with(authentication(doctor()))).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        mvc.perform(get("/api/reports/clinical").param("from","2026-10-26").param("to","2026-10-01").with(authentication(doctor()))).andExpect(status().isBadRequest());org.mockito.Mockito.verifyNoInteractions(jdbc,audit);
    }
    @Test void permissionsAndBackendFailureAreNotEmptySuccess() throws Exception {
        for(String role:List.of("STUDENT","AUDITOR"))mvc.perform(get("/api/reports/clinical").with(user("other").roles(role))).andExpect(status().isForbidden());
        mvc.perform(get("/api/reports/clinical")).andExpect(status().isUnauthorized());
        when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenThrow(new org.springframework.dao.DataIntegrityViolationException("backend unavailable"));mvc.perform(get("/api/reports/clinical").with(authentication(doctor()))).andExpect(status().isInternalServerError()).andExpect(jsonPath("$.error").isString());
    }
}

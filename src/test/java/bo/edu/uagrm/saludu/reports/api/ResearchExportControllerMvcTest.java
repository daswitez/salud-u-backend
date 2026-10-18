package bo.edu.uagrm.saludu.reports.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.io.ByteArrayInputStream;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import java.util.zip.ZipInputStream;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(ResearchExportController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class ResearchExportControllerMvcTest {
    @Autowired MockMvc mvc; @MockBean JdbcTemplate jdbc; @MockBean DatabaseActorContext actors; @MockBean AuthenticationService authenticationService; @MockBean SessionCookieService sessionCookieService;
    @Test void reportingOfficerDownloadsDataAndDictionary() throws Exception {
        when(jdbc.query(eq("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))"), any(RowMapper.class), any())).thenAnswer(invocation -> { @SuppressWarnings("unchecked") RowMapper<Object> mapper = invocation.getArgument(1); ResultSet row = mock(ResultSet.class); when(row.getString("seudonimo")).thenReturn("R-0123456789ABCDEF0123"); when(row.getObject(eq("mes_atencion"), eq(LocalDate.class))).thenReturn(LocalDate.of(2026, 10, 1)); when(row.getString("rango_edad")).thenReturn("20_24"); when(row.getString("codigo_carrera")).thenReturn("MED"); when(row.getString("periodo_academico")).thenReturn("2026-II"); when(row.getString("tipo_encuentro")).thenReturn("INITIAL"); when(row.getString("codigo_especialidad")).thenReturn(null); when(row.getInt("cantidad_diagnosticos")).thenReturn(1); when(row.getInt("cantidad_dosis_vacuna")).thenReturn(2); return List.of(mapper.mapRow(row, 0)); });
        UUID export = UUID.randomUUID(); when(jdbc.queryForObject(eq("select salud_u.registrar_exportacion_investigacion(?, cast(? as jsonb), ?, ?)"), eq(UUID.class), any(), any(), any(), any())).thenReturn(export);
        var result = mvc.perform(post("/api/research/exports").with(authentication(authenticationFor("REPORTING_OFFICER"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"purpose\":\"Estudio institucional\",\"filters\":{},\"format\":\"CSV\"}"))
            .andExpect(status().isOk()).andReturn();
        try (var zip = new ZipInputStream(new ByteArrayInputStream(result.getResponse().getContentAsByteArray()))) { assertEntries(zip); }
    }
    @Test void unrelatedRoleCannotExportResearch() throws Exception { mvc.perform(post("/api/research/exports").with(authentication(authenticationFor("STUDENT"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"purpose\":\"Estudio institucional\",\"filters\":{},\"format\":\"CSV\"}")).andExpect(status().isForbidden()); }
    private static void assertEntries(ZipInputStream zip) throws Exception { org.junit.jupiter.api.Assertions.assertEquals("research-data.csv", zip.getNextEntry().getName()); org.junit.jupiter.api.Assertions.assertTrue(new String(zip.readAllBytes()).contains("research_pseudonym")); org.junit.jupiter.api.Assertions.assertEquals("dictionary.csv", zip.getNextEntry().getName()); org.junit.jupiter.api.Assertions.assertTrue(new String(zip.readAllBytes()).contains("age_band")); }
    private static UsernamePasswordAuthenticationToken authenticationFor(String role) { SessionPrincipal principal = new SessionPrincipal(UUID.randomUUID(), "research@example.invalid", "Investigación", List.of(role)); return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role))); }
}

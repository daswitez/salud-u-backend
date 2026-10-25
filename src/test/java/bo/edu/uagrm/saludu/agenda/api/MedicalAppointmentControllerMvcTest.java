package bo.edu.uagrm.saludu.agenda.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.sql.ResultSet;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.RowMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(MedicalAppointmentController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class MedicalAppointmentControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbcTemplate;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuditWriter auditWriter;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void createsDraftEncounterWith201() throws Exception {
        UUID appointmentId = UUID.fromString("00000000-0000-4000-8000-000000000091");
        UUID encounterId = UUID.fromString("00000000-0000-4000-8000-000000000092");
        when(jdbcTemplate.queryForMap(eq("select * from salud_u.abrir_encuentro_borrador(?)"), eq(appointmentId)))
            .thenReturn(Map.of("id_encuentro", encounterId, "estado", "DRAFT", "creado", true));

        mvc.perform(post("/api/medical/appointments/{id}/start", appointmentId).with(authentication(doctorAuthentication())).with(csrf()))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.encounterId").value(encounterId.toString()))
            .andExpect(jsonPath("$.data.status").value("DRAFT"));
    }

    @Test
    void recoversExistingDraftWith200() throws Exception {
        UUID appointmentId = UUID.fromString("00000000-0000-4000-8000-000000000091");
        UUID encounterId = UUID.fromString("00000000-0000-4000-8000-000000000092");
        when(jdbcTemplate.queryForMap(eq("select * from salud_u.abrir_encuentro_borrador(?)"), eq(appointmentId)))
            .thenReturn(Map.of("id_encuentro", encounterId, "estado", "DRAFT", "creado", false));

        mvc.perform(post("/api/medical/appointments/{id}/start", appointmentId).with(authentication(doctorAuthentication())).with(csrf()))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.encounterId").value(encounterId.toString()));
    }

    private static UsernamePasswordAuthenticationToken doctorAuthentication() {
        SessionPrincipal doctor = new SessionPrincipal(UUID.fromString("00000000-0000-4000-8000-000000000090"), "doctor@example.invalid", "Médico", List.of("REVIEW_DOCTOR"));
        return new UsernamePasswordAuthenticationToken(doctor, null, List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));
    }

    @Test
    void listPreservesIdentityNullableFieldsAndEmptyResult() throws Exception {
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("id", UUID.class)).thenReturn(UUID.fromString("00000000-0000-4000-8000-000000000091"));
        when(row.getObject("id_paciente", UUID.class)).thenReturn(UUID.fromString("00000000-0000-4000-8000-000000000092"));
        when(row.getString("tipo_cita")).thenReturn("INITIAL");
        when(row.getString("estado_cita")).thenReturn("SCHEDULED");
        when(row.getString("nombres")).thenReturn("Paciente");
        when(row.getString("apellidos")).thenReturn("Prueba");
        when(row.getString("codigo_registro")).thenReturn("REG-FE09");
        when(jdbcTemplate.query(eq("select * from salud_u.listar_mis_citas_medicas()"), any(RowMapper.class)))
            .thenAnswer(invocation -> List.of(((RowMapper<?>) invocation.getArgument(1)).mapRow(row, 0)));
        mvc.perform(get("/api/medical/appointments").with(authentication(doctorAuthentication())))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data[0].patient.registrationCode").value("REG-FE09"))
            .andExpect(jsonPath("$.data[0].specialty").value("Revisión estudiantil"))
            .andExpect(jsonPath("$.data[0].checkedInAt").hasJsonPath())
            .andExpect(jsonPath("$.data[0].patient.phone").hasJsonPath())
            .andExpect(jsonPath("$.data[0].encounter").hasJsonPath());
        when(jdbcTemplate.query(eq("select * from salud_u.listar_mis_citas_medicas()"), any(RowMapper.class))).thenReturn(List.of());
        mvc.perform(get("/api/medical/appointments").with(authentication(doctorAuthentication())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data").isEmpty());
    }

    @Test
    void refusesForeignAndNonStartableAppointmentsWithoutAuditingSuccess() throws Exception {
        UUID id = UUID.randomUUID();
        when(jdbcTemplate.queryForMap(eq("select * from salud_u.abrir_encuentro_borrador(?)"), eq(id)))
            .thenThrow(new DataIntegrityViolationException("CITA_AJENA_O_INEXISTENTE"));
        mvc.perform(post("/api/medical/appointments/{id}/start", id).with(authentication(doctorAuthentication())).with(csrf()))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").isString());
        when(jdbcTemplate.queryForMap(eq("select * from salud_u.abrir_encuentro_borrador(?)"), eq(id)))
            .thenThrow(new DataIntegrityViolationException("CITA_NO_INICIABLE"));
        mvc.perform(post("/api/medical/appointments/{id}/start", id).with(authentication(doctorAuthentication())).with(csrf()))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.error").isString());
        verifyNoInteractions(auditWriter);
    }

    @Test
    void rejectsNonMedicalActorAndMissingCsrf() throws Exception {
        SessionPrincipal admin = new SessionPrincipal(UUID.randomUUID(), "admin@example.invalid", "Admin", List.of("ADMINISTRATIVE"));
        var auth = new UsernamePasswordAuthenticationToken(admin, null, List.of(new SimpleGrantedAuthority("ROLE_ADMINISTRATIVE")));
        mvc.perform(get("/api/medical/appointments").with(authentication(auth))).andExpect(status().isForbidden());
        mvc.perform(post("/api/medical/appointments/{id}/start", UUID.randomUUID()).with(authentication(auth)).with(csrf()))
            .andExpect(status().isForbidden());
        mvc.perform(post("/api/medical/appointments/{id}/start", UUID.randomUUID()).with(authentication(doctorAuthentication())))
            .andExpect(status().isForbidden());
        verifyNoInteractions(jdbcTemplate);
    }
}

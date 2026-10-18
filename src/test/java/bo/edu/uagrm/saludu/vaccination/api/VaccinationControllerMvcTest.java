package bo.edu.uagrm.saludu.vaccination.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.sql.ResultSet;
import java.util.List;
import java.util.UUID;
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

@WebMvcTest(VaccinationController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class VaccinationControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void administrativeActorRegistersDoseWithCharacterizedContract() throws Exception {
        UUID id = UUID.randomUUID(), applicator = UUID.randomUUID(), registeredBy = UUID.randomUUID();
        when(jdbc.queryForObject(eq("select * from salud_u.registrar_dosis_vacuna(?, ?, ?, ?, ?, ?, ?)"), any(RowMapper.class), any(), any(), any(), any(), any(), any(), any())).thenAnswer(invocation -> {
            @SuppressWarnings("unchecked") RowMapper<Object> mapper = invocation.getArgument(1);
            ResultSet row = mock(ResultSet.class);
            when(row.getObject("id", UUID.class)).thenReturn(id);
            when(row.getBoolean("advertencia_intervalo")).thenReturn(false);
            when(row.getObject("id_personal_aplicador", UUID.class)).thenReturn(applicator);
            when(row.getObject("id_registrado_por", UUID.class)).thenReturn(registeredBy);
            when(row.getObject(eq("fecha_aplicacion"), eq(java.time.LocalDate.class))).thenReturn(java.time.LocalDate.of(2026, 10, 17));
            return mapper.mapRow(row, 0);
        });
        mvc.perform(post("/api/vaccinations").with(authentication(authenticationFor("ADMINISTRATIVE"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body()))
            .andExpect(status().isCreated()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data.id").value(id.toString())).andExpect(jsonPath("$.data.intervalWarning").value(false)).andExpect(jsonPath("$.data.applicatorStaffId").value(applicator.toString())).andExpect(jsonPath("$.data.registeredBy").value(registeredBy.toString()));
    }

    @Test
    void specialistCannotRegisterDose() throws Exception {
        mvc.perform(post("/api/vaccinations").with(authentication(authenticationFor("SPECIALIST"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body()))
            .andExpect(status().isForbidden());
    }

    @Test
    void rejectsIncompleteDoseBeforePersistence() throws Exception {
        mvc.perform(post("/api/vaccinations").with(authentication(authenticationFor("ADMINISTRATIVE"))).with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"patientId\":\"" + UUID.randomUUID() + "\"}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.ok").value(false));
    }

    private static String body() { return "{\"patientId\":\"" + UUID.randomUUID() + "\",\"vaccineId\":\"" + UUID.randomUUID() + "\",\"doseNumber\":1,\"appliedOn\":\"2026-10-17\",\"lot\":\"LOTE-1\",\"applicatorStaffId\":\"" + UUID.randomUUID() + "\"}"; }
    private static UsernamePasswordAuthenticationToken authenticationFor(String role) { SessionPrincipal principal = new SessionPrincipal(UUID.randomUUID(), "vaccine@example.invalid", "Vacunas", List.of(role)); return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role))); }
}

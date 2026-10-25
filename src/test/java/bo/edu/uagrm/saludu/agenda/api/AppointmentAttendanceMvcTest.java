package bo.edu.uagrm.saludu.agenda.api;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

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
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest({AppointmentAttendanceController.class, AppointmentRequestController.class})
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class AppointmentAttendanceMvcTest {
    @Autowired MockMvc mvc;
    @MockBean JdbcTemplate jdbc;
    @MockBean DatabaseActorContext actorContext;
    @MockBean AuditWriter audit;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;
    private static final UUID ID = UUID.fromString("00000000-0000-4000-8000-000000000808");

    private static UsernamePasswordAuthenticationToken actor(String role) {
        return new UsernamePasswordAuthenticationToken(
            new SessionPrincipal(ID, "fe08@example.invalid", "FE08", List.of(role)), null,
            List.of(new SimpleGrantedAuthority("ROLE_" + role))
        );
    }

    @Test void successfulAttendanceRetainsNullDataContract() throws Exception {
        mvc.perform(post("/api/appointments/{id}/check-in", ID).with(authentication(actor("ADMINISTRATIVE"))).with(csrf()))
            .andExpect(status().isOk()).andExpect(content().json("{\"ok\":true,\"data\":null}"));
        mvc.perform(post("/api/appointments/{id}/no-show", ID).with(authentication(actor("ADMINISTRATIVE"))).with(csrf())
            .contentType("application/json").content("{\"reason\":\"Prueba\"}"))
            .andExpect(status().isOk()).andExpect(content().json("{\"ok\":true,\"data\":null}"));
    }

    @Test void studentCannotChangeAttendanceAndCsrfIsRequired() throws Exception {
        mvc.perform(post("/api/appointments/{id}/check-in", ID).with(authentication(actor("STUDENT"))).with(csrf()))
            .andExpect(status().isForbidden());
        mvc.perform(post("/api/appointments/{id}/no-show", ID).with(authentication(actor("STUDENT"))).with(csrf()))
            .andExpect(status().isForbidden());
        mvc.perform(post("/api/appointments/{id}/check-in", ID).with(authentication(actor("ADMINISTRATIVE"))))
            .andExpect(status().isForbidden());
        verifyNoInteractions(jdbc);
    }

    @Test void staleAttendanceReturnsTextConflictRatherThanAuthenticationError() throws Exception {
        doThrow(new DataIntegrityViolationException("La cita no puede registrar ingreso"))
            .when(jdbc).query(eq("select salud_u.registrar_llegada_cita(?)"), any(RowCallbackHandler.class), eq(ID));
        mvc.perform(post("/api/appointments/{id}/check-in", ID).with(authentication(actor("ADMINISTRATIVE"))).with(csrf()))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.error").isString());
        verifyNoInteractions(audit);
    }

    @Test void invalidReasonDoesNotWrite() throws Exception {
        mvc.perform(post("/api/appointments/{id}/no-show", ID).with(authentication(actor("ADMINISTRATIVE"))).with(csrf())
            .contentType("application/json").content("{\"reason\":123}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        verifyNoInteractions(jdbc);
    }

    @Test void foreignCancellationIsHiddenAndStaleCancellationIsRecoverable() throws Exception {
        doThrow(new DataIntegrityViolationException("No autorizado para cancelar la solicitud"))
            .when(jdbc).query(eq("select salud_u.cancelar_solicitud_cita(?,?)"), any(RowCallbackHandler.class), eq(ID), isNull());
        mvc.perform(patch("/api/appointment-requests/{id}", ID).with(authentication(actor("STUDENT"))).with(csrf())
            .contentType("application/json").content("{\"action\":\"cancel\"}"))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("Solicitud no encontrada."));
        doThrow(new DataIntegrityViolationException("La cita asignada ya no puede cancelarse"))
            .when(jdbc).query(eq("select salud_u.cancelar_solicitud_cita(?,?)"), any(RowCallbackHandler.class), eq(ID), isNull());
        mvc.perform(patch("/api/appointment-requests/{id}", ID).with(authentication(actor("STUDENT"))).with(csrf())
            .contentType("application/json").content("{\"action\":\"cancel\"}"))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.error").isString());
        verifyNoInteractions(audit);
    }
}

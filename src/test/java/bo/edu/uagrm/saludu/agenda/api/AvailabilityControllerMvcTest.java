package bo.edu.uagrm.saludu.agenda.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(AvailabilityController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class AvailabilityControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean AvailabilityService availabilityService;

    @Test
    void scheduleReplacementRequiresCsrf() throws Exception {
        mvc.perform(post("/api/availability-slots").with(authentication(clinicianAuthentication()))
                .contentType(MediaType.APPLICATION_JSON).content(scheduleBody()))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.error").value("forbidden"));
    }

    @Test
    void clinicianCanReplaceScheduleAndReceiveGeneratedSlots() throws Exception {
        when(availabilityService.replace(eq(clinician()), any(), any())).thenReturn(12);

        mvc.perform(post("/api/availability-slots").with(authentication(clinicianAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(scheduleBody()))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.generatedSlots").value(12));
        verify(availabilityService).replace(eq(clinician()), any(), any());
    }

    @Test
    void administrativeActorCannotManageClinicianCalendar() throws Exception {
        mvc.perform(get("/api/availability-slots").param("manage", "true").with(authentication(administratorAuthentication())))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("La agenda de disponibilidad pertenece al médico."));
    }

    @Test
    void managementKeepsExpectedCollectionsAndDateRange() throws Exception {
        when(availabilityService.management(eq(clinician()), eq(LocalDate.of(2026, 10, 12)), eq(LocalDate.of(2026, 10, 12))))
            .thenReturn(Map.of("schedules", List.of(), "recurringBlocks", List.of(), "dateBlocks", List.of(), "slots", List.of(), "appointments", List.of()));

        mvc.perform(get("/api/availability-slots").param("manage", "true").param("from", "2026-10-12").param("to", "2026-10-12").with(authentication(clinicianAuthentication())))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.schedules").isArray())
            .andExpect(jsonPath("$.data.appointments").isArray());
    }

    private static String scheduleBody() {
        return "{\"rules\":[{\"weekday\":1,\"startsAt\":\"08:00\",\"endsAt\":\"10:00\",\"slotDurationMinutes\":30,\"specialtyId\":null}],\"recurringBlocks\":[{\"weekday\":1,\"startsAt\":\"09:00\",\"endsAt\":\"09:30\",\"label\":\"Pausa\"}]}";
    }

    private static SessionPrincipal clinician() {
        return new SessionPrincipal(UUID.fromString("00000000-0000-4000-8000-000000000040"), "doctor@example.invalid", "Médico sintético", List.of("REVIEW_DOCTOR"));
    }

    private static UsernamePasswordAuthenticationToken clinicianAuthentication() {
        return new UsernamePasswordAuthenticationToken(clinician(), null, List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));
    }

    private static UsernamePasswordAuthenticationToken administratorAuthentication() {
        SessionPrincipal administrator = new SessionPrincipal(UUID.randomUUID(), "admin@example.invalid", "Administración", List.of("ADMINISTRATIVE"));
        return new UsernamePasswordAuthenticationToken(administrator, null, List.of(new SimpleGrantedAuthority("ROLE_ADMINISTRATIVE")));
    }
}

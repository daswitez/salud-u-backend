package bo.edu.uagrm.saludu.notifications.api;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.notifications.application.*;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(NotificationController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class NotificationControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean NotificationService notifications;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void allAuthenticatedRolesCanReadTheirOwnPageAndCounter() throws Exception {
        var time = OffsetDateTime.parse("2026-10-26T22:00:00.123456Z");
        var item = new Notification(UUID.randomUUID(), UUID.randomUUID(), "APPOINTMENT_ASSIGNED", "INBOX", "Cita asignada", "Mensaje", "DELIVERED", time, time, null, time);
        when(notifications.list(any(), eq(50), isNull(), isNull())).thenReturn(new NotificationPage(true, List.of(item), new NotificationPage.Pagination(false, null), 1));
        for (String role : List.of("ADMINISTRATIVE", "REVIEW_DOCTOR", "SPECIALIST", "STUDENT", "AUDITOR", "REPORTING_OFFICER")) {
            mvc.perform(get("/api/notifications").with(authentication(actor(role))))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data[0].status").value("DELIVERED"))
                .andExpect(jsonPath("$.data[0].appointmentId").value(item.appointmentId().toString()))
                .andExpect(jsonPath("$.data[0].id_destinatario").doesNotExist()).andExpect(jsonPath("$.data[0].recipientId").doesNotExist())
                .andExpect(jsonPath("$.unreadCount").value(1)).andExpect(jsonPath("$.pagination.hasMore").value(false))
                .andExpect(header().string("Cache-Control", "no-store, private"));
        }
    }

    @Test
    void cursorRetainsMicrosecondsAndNotificationId() throws Exception {
        var time = OffsetDateTime.parse("2026-10-26T22:00:00.123456Z");
        var id = UUID.randomUUID();
        when(notifications.list(any(), eq(1), eq(time), eq(id))).thenReturn(new NotificationPage(true, List.of(), new NotificationPage.Pagination(false, null), 0));
        mvc.perform(get("/api/notifications").param("limit", "1").param("before", time + "|" + id).with(authentication(actor("STUDENT"))))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data").isEmpty());
        verify(notifications).list(any(), eq(1), eq(time), eq(id));
    }

    @Test
    void invalidPaginationAndUuidDoNotReachService() throws Exception {
        for (String limit : List.of("0", "-1", "101", "bad"))
            mvc.perform(get("/api/notifications").param("limit", limit).with(authentication(actor("STUDENT"))))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        for (String cursor : List.of("", "bad", "x".repeat(121), "2026-10-26T10:00:00Z|1-1-1-1-1", "2026-10-26T10:00:00Z|" + UUID.randomUUID() + "|extra"))
            mvc.perform(get("/api/notifications").param("before", cursor).with(authentication(actor("STUDENT"))))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        mvc.perform(patch("/api/notifications/not-a-uuid/read").with(authentication(actor("STUDENT"))).with(csrf()))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        verifyNoInteractions(notifications);
    }

    @Test
    void markReadReturnsOwnNotificationAndIsCsrfProtected() throws Exception {
        UUID id = UUID.randomUUID();
        var time = OffsetDateTime.parse("2026-10-26T22:00:00Z");
        when(notifications.markRead(any(), eq(id))).thenReturn(new Notification(id, UUID.randomUUID(), "APPOINTMENT_ASSIGNED", "INBOX", "Cita", "Mensaje", "READ", time, time, time, time));
        mvc.perform(patch("/api/notifications/{id}/read", id).with(authentication(actor("STUDENT"))))
            .andExpect(status().isForbidden());
        verifyNoInteractions(notifications);
        mvc.perform(patch("/api/notifications/{id}/read", id).with(authentication(actor("STUDENT"))).with(csrf()))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.id").value(id.toString())).andExpect(jsonPath("$.data.status").value("READ"))
            .andExpect(header().string("Cache-Control", "no-store, private"));
    }

    @Test
    void foreignAndMissingNotificationsHaveTheSame404Body() throws Exception {
        when(notifications.markRead(any(), any())).thenThrow(new AvailabilityException(404, "Notificación no encontrada."));
        String body = null;
        for (int n = 0; n < 2; n++) {
            String current = mvc.perform(patch("/api/notifications/{id}/read", UUID.randomUUID()).with(authentication(actor("STUDENT"))).with(csrf()))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.ok").value(false)).andExpect(jsonPath("$.error").value("Notificación no encontrada."))
                .andReturn().getResponse().getContentAsString();
            if (body != null) org.junit.jupiter.api.Assertions.assertEquals(body, current);
            body = current;
        }
    }

    @Test
    void preferencesGetAndPutOnlyUseTheAuthenticatedPrincipal() throws Exception {
        var auth = actor("AUDITOR");
        when(notifications.preferences(any())).thenReturn(new NotificationPreferences(true, true, null));
        when(notifications.savePreferences(any(), eq(false), eq(true))).thenReturn(new NotificationPreferences(false, true, OffsetDateTime.now()));
        mvc.perform(get("/api/me/notification-preferences").with(authentication(auth)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.receiveReminders").value(true)).andExpect(jsonPath("$.data.reinforcedReminder").value(true))
            .andExpect(header().string("Cache-Control", "no-store, private"));
        mvc.perform(put("/api/me/notification-preferences").contentType("application/json").content("{\"receiveReminders\":false,\"reinforcedReminder\":true}").with(authentication(auth)).with(csrf()))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.receiveReminders").value(false));
        verify(notifications).savePreferences(eq((SessionPrincipal) auth.getPrincipal()), eq(false), eq(true));
    }

    @Test
    void preferencesRequireTwoStrictBooleansAndNoForeignIdentityOrMailFields() throws Exception {
        for (String body : List.of("{}", "null", "[]", "{\"receiveReminders\":true}", "{\"receiveReminders\":\"true\",\"reinforcedReminder\":false}",
            "{\"receiveReminders\":false,\"reinforcedReminder\":null}", "{\"receiveReminders\":true,\"reinforcedReminder\":false,\"principalId\":\"other\"}",
            "{\"receiveReminders\":true,\"reinforcedReminder\":false,\"email\":true}")) {
            mvc.perform(put("/api/me/notification-preferences").contentType("application/json").content(body).with(authentication(actor("STUDENT"))).with(csrf()))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
        }
        mvc.perform(put("/api/me/notification-preferences").contentType("application/json").content("{\"receiveReminders\":true,\"reinforcedReminder\":true}").with(authentication(actor("STUDENT"))))
            .andExpect(status().isForbidden());
        verifyNoInteractions(notifications);
    }

    @Test
    void everyEndpointRequiresAnAuthenticatedSession() throws Exception {
        mvc.perform(get("/api/notifications")).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/me/notification-preferences")).andExpect(status().isUnauthorized());
        mvc.perform(patch("/api/notifications/{id}/read", UUID.randomUUID()).with(csrf())).andExpect(status().isUnauthorized());
        mvc.perform(put("/api/me/notification-preferences").contentType("application/json").content("{}").with(csrf())).andExpect(status().isUnauthorized());
        verifyNoInteractions(notifications);
    }

    @Test
    void databaseErrorsAreSanitizedInsteadOfReturningAnEmptyInbox() throws Exception {
        when(notifications.list(any(), anyInt(), any(), any())).thenThrow(new DataAccessResourceFailureException("SELECT secret_database_detail"));
        mvc.perform(get("/api/notifications").with(authentication(actor("STUDENT"))))
            .andExpect(status().isInternalServerError()).andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("No se pudo completar la operación. Inténtalo nuevamente."));
    }

    private static UsernamePasswordAuthenticationToken actor(String role) {
        var principal = new SessionPrincipal(UUID.randomUUID(), "actor@example.invalid", "Actor N02", List.of(role));
        return new UsernamePasswordAuthenticationToken(principal, null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
    }
}

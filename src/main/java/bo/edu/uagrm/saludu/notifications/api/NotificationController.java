package bo.edu.uagrm.saludu.notifications.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.notifications.application.Notification;
import bo.edu.uagrm.saludu.notifications.application.NotificationPage;
import bo.edu.uagrm.saludu.notifications.application.NotificationPreferences;
import bo.edu.uagrm.saludu.notifications.application.NotificationService;
import com.fasterxml.jackson.databind.JsonNode;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@PreAuthorize("isAuthenticated()")
public class NotificationController {
    private final NotificationService notifications;
    public NotificationController(NotificationService notifications) { this.notifications = notifications; }

    @GetMapping("/api/notifications")
    public ResponseEntity<NotificationPage> list(@RequestParam(defaultValue = "50") int limit,
        @RequestParam(required = false) String before, @AuthenticationPrincipal SessionPrincipal principal) {
        if (limit < 1 || limit > 100) throw invalidPagination();
        OffsetDateTime time = null;
        UUID id = null;
        if (before != null) {
            if (before.length() > 120) throw invalidPagination();
            String[] parts = before.split("\\|", -1);
            if (parts.length != 2) throw invalidPagination();
            try {
                time = OffsetDateTime.parse(parts[0]);
                id = UUID.fromString(parts[1]);
                if (!id.toString().equalsIgnoreCase(parts[1])) throw invalidPagination();
            } catch (IllegalArgumentException | DateTimeParseException exception) { throw invalidPagination(); }
        }
        return response(notifications.list(principal, limit, time, id));
    }

    @PatchMapping("/api/notifications/{id}/read")
    public ResponseEntity<LegacyAvailabilityResponse<Notification>> markRead(@PathVariable UUID id,
        @AuthenticationPrincipal SessionPrincipal principal) {
        return response(LegacyAvailabilityResponse.success(notifications.markRead(principal, id)));
    }

    @GetMapping("/api/me/notification-preferences")
    public ResponseEntity<LegacyAvailabilityResponse<NotificationPreferences>> preferences(@AuthenticationPrincipal SessionPrincipal principal) {
        return response(LegacyAvailabilityResponse.success(notifications.preferences(principal)));
    }

    @PutMapping("/api/me/notification-preferences")
    public ResponseEntity<LegacyAvailabilityResponse<NotificationPreferences>> savePreferences(@RequestBody JsonNode body,
        @AuthenticationPrincipal SessionPrincipal principal) {
        if (!body.isObject() || body.size() != 2 || !body.path("receiveReminders").isBoolean() || !body.path("reinforcedReminder").isBoolean())
            throw new AvailabilityException(400, "Indica ambas preferencias de recordatorios como valores booleanos.");
        return response(LegacyAvailabilityResponse.success(notifications.savePreferences(principal,
            body.path("receiveReminders").booleanValue(), body.path("reinforcedReminder").booleanValue())));
    }

    private static AvailabilityException invalidPagination() { return new AvailabilityException(400, "Los parámetros de paginación no son válidos."); }
    private static <T> ResponseEntity<T> response(T data) { return ResponseEntity.ok().header("Cache-Control", "no-store, private").body(data); }
}

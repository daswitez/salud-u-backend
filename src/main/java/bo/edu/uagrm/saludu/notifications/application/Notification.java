package bo.edu.uagrm.saludu.notifications.application;

import java.time.OffsetDateTime;
import java.util.UUID;

public record Notification(UUID id, UUID appointmentId, String eventType, String channel, String subject,
    String message, String status, OffsetDateTime scheduledFor, OffsetDateTime deliveredAt,
    OffsetDateTime readAt, OffsetDateTime createdAt) {}

package bo.edu.uagrm.saludu.notifications.application;

import java.time.OffsetDateTime;

public record NotificationPreferences(boolean receiveReminders, boolean reinforcedReminder, OffsetDateTime updatedAt) {}

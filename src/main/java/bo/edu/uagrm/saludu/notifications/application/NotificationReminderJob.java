package bo.edu.uagrm.saludu.notifications.application;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(name = "salud-u.scheduling.enabled", havingValue = "true")
public class NotificationReminderJob {
    private static final Logger LOG = LoggerFactory.getLogger(NotificationReminderJob.class);
    private final NotificationReminderService reminders;

    public NotificationReminderJob(NotificationReminderService reminders) { this.reminders = reminders; }

    @Scheduled(cron = "${salud-u.scheduling.reminder-cron:0 */15 * * * *}", zone = "America/La_Paz")
    public void generate() {
        try {
            int count = reminders.generateTomorrowReminders();
            if (count > 0) LOG.info("Recordatorios de citas creados o actualizados: {}", count);
        } catch (RuntimeException exception) {
            LOG.error("No se pudieron generar recordatorios; se reintentará en la próxima ejecución.", exception);
        }
    }
}

package bo.edu.uagrm.saludu.notifications.application;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class NotificationReminderService {
    private final JdbcTemplate jdbc;

    public NotificationReminderService(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    @Transactional
    public int generateTomorrowReminders() {
        return jdbc.queryForObject("select salud_u.generar_recordatorios_citas()", Integer.class);
    }
}

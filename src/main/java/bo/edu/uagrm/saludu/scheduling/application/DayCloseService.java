package bo.edu.uagrm.saludu.scheduling.application;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** O-02: consolida las jornadas de los siete días anteriores. Solo lee agenda y calendario (RN-34). */
@Service
public class DayCloseService {
    private final JdbcTemplate jdbc;

    public DayCloseService(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    @Transactional
    public int closeRecentDays() {
        return jdbc.queryForObject("select salud_u.cerrar_jornadas_recientes()", Integer.class);
    }
}

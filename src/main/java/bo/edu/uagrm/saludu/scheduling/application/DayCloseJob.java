package bo.edu.uagrm.saludu.scheduling.application;

import java.time.LocalDate;
import java.time.ZoneId;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** O-02 a O-06: cierra las jornadas recientes, recalcula las estimaciones, vence lo no decidido y regenera las sugerencias. */
@Component
@ConditionalOnProperty(name = "salud-u.scheduling.enabled", havingValue = "true")
public class DayCloseJob {
    private static final Logger LOG = LoggerFactory.getLogger(DayCloseJob.class);
    private static final ZoneId BOLIVIA = ZoneId.of("America/La_Paz");
    private final DayCloseService days;
    private final ScheduleEstimationService estimations;
    private final ScheduleSuggestionService suggestions;

    public DayCloseJob(DayCloseService days, ScheduleEstimationService estimations, ScheduleSuggestionService suggestions) {
        this.days = days;
        this.estimations = estimations;
        this.suggestions = suggestions;
    }

    @Scheduled(cron = "${salud-u.scheduling.day-close-cron:0 30 0 * * *}", zone = "America/La_Paz")
    public void close() {
        long iniciado = System.nanoTime();
        int errores = 0;
        LOG.info("Actualización diaria: inicio.");
        try {
            int count = days.closeRecentDays();
            LOG.info("Cierre de jornadas: {} observaciones creadas, actualizadas o retiradas.", count);
        } catch (RuntimeException exception) {
            errores++;
            LOG.error("No se pudieron cerrar las jornadas; se reintentará en la próxima ejecución.", exception);
        }
        // Se estima aunque el cierre falle: las observaciones anteriores siguen siendo válidas.
        try {
            int count = estimations.recompute();
            LOG.info("Estimaciones de agenda recalculadas: {} filas ({}).", count, EstimadorAgenda.VERSION_MODELO);
        } catch (RuntimeException exception) {
            errores++;
            LOG.error("No se pudieron recalcular las estimaciones; se conservan las anteriores.", exception);
        }
        try {
            int count = suggestions.expire();
            LOG.info("Sugerencias vencidas sin decisión: {}.", count);
        } catch (RuntimeException exception) {
            errores++;
            LOG.error("No se pudieron marcar las sugerencias vencidas; se reintentará en la próxima ejecución.", exception);
        }
        try {
            int count = suggestions.generate(LocalDate.now(BOLIVIA));
            LOG.info("Sugerencias de agenda regeneradas: {} cambios ({}).", count, SugeridorAgenda.VERSION_MODELO);
        } catch (RuntimeException exception) {
            errores++;
            LOG.error("No se pudieron regenerar las sugerencias; se conservan las anteriores.", exception);
        }
        LOG.info("Actualización diaria: fin; duración_ms={}; errores={}", (System.nanoTime() - iniciado) / 1_000_000, errores);
    }
}

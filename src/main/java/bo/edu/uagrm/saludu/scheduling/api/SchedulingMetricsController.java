package bo.edu.uagrm.saludu.scheduling.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.scheduling.application.SchedulingMetrics;
import bo.edu.uagrm.saludu.scheduling.application.SchedulingMetricsService;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@PreAuthorize("hasRole('ADMINISTRATIVE')")
public class SchedulingMetricsController {
    private final SchedulingMetricsService metrics;

    public SchedulingMetricsController(SchedulingMetricsService metrics) { this.metrics = metrics; }

    /** Indicadores del componente para [from, to]. Por defecto, los 30 días que terminan ayer (hora de Bolivia). */
    @GetMapping("/api/scheduling/metrics")
    public ResponseEntity<LegacyAvailabilityResponse<SchedulingMetrics>> get(@RequestParam(required = false) String from,
        @RequestParam(required = false) String to, @AuthenticationPrincipal SessionPrincipal principal) {
        LocalDate end, start;
        try {
            end = to == null ? LocalDate.now(ZoneId.of("America/La_Paz")).minusDays(1) : LocalDate.parse(to);
            start = from == null ? end.minusDays(29) : LocalDate.parse(from);
        } catch (DateTimeParseException exception) { throw SchedulingMetricsService.invalidPeriod(); }
        return ResponseEntity.ok().header("Cache-Control", "no-store, private").body(LegacyAvailabilityResponse.success(metrics.metrics(principal, start, end)));
    }
}

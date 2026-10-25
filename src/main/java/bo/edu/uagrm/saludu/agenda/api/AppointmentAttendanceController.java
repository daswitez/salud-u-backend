package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/appointments")
public class AppointmentAttendanceController {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final AuditWriter audit;

    public AppointmentAttendanceController(JdbcTemplate jdbc, DatabaseActorContext actorContext, AuditWriter audit) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.audit = audit;
    }

    @PostMapping("/{id}/check-in")
    @PreAuthorize("hasRole('ADMINISTRATIVE')")
    @Transactional
    public AppointmentMutationResponse checkIn(@PathVariable UUID id, @AuthenticationPrincipal SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try {
            jdbc.query("select salud_u.registrar_llegada_cita(?)", row -> {}, id);
            audit.append("APPOINTMENT_CHECKED_IN", "appointment", id, AuditOutcome.SUCCESS, Map.of());
            return AppointmentMutationResponse.success();
        } catch (DataAccessException exception) {
            throw new AvailabilityException(409, "La cita no puede registrar ingreso.");
        }
    }

    @PostMapping("/{id}/no-show")
    @PreAuthorize("hasRole('ADMINISTRATIVE')")
    @Transactional
    public AppointmentMutationResponse noShow(
        @PathVariable UUID id, @RequestBody(required = false) Map<String, Object> body,
        @AuthenticationPrincipal SessionPrincipal principal
    ) {
        Object reason = body == null ? null : body.get("reason");
        if (reason != null && (!(reason instanceof String text) || text.length() > 300)) {
            throw new AvailabilityException(400, "El motivo debe ser texto de hasta 300 caracteres.");
        }
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try {
            jdbc.query("select salud_u.registrar_ausencia_cita(?,?)", row -> {}, id, reason);
            audit.append("APPOINTMENT_NO_SHOW", "appointment", id, AuditOutcome.SUCCESS, Map.of());
            return AppointmentMutationResponse.success();
        } catch (DataAccessException exception) {
            throw new AvailabilityException(409, "La cita no puede marcarse como inasistencia.");
        }
    }
}

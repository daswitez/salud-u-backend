package bo.edu.uagrm.saludu.agenda.api;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.*;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import java.util.*;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/appointment-requests")
public class AppointmentAssignmentController {
    private final JdbcTemplate j;
    private final DatabaseActorContext c;
    private final AuditWriter a;

    public AppointmentAssignmentController(JdbcTemplate j, DatabaseActorContext c, AuditWriter a) {
        this.j = j;
        this.c = c;
        this.a = a;
    }

    @PostMapping("/{requestId}/assign")
    @PreAuthorize("hasRole('ADMINISTRATIVE')")
    @Transactional
    public LegacyAvailabilityResponse<Map<String, UUID>> assign(
        @PathVariable UUID requestId,
        @RequestBody Map<String, Object> body,
        @AuthenticationPrincipal SessionPrincipal principal
    ) {
        Object raw = body.get("slotId");
        if (!(raw instanceof String slot) || slot.isBlank()) {
            throw new AvailabilityException(400, "Selecciona un cupo para asignar.");
        }

        UUID slotId = UUID.fromString(slot);
        c.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try {
            UUID appointmentId = j.queryForObject(
                "select salud_u.asignar_solicitud_cita(?,?)", UUID.class, requestId, slotId
            );
            a.append(
                "APPOINTMENT_REQUEST_ASSIGNED", "appointment_request", requestId, AuditOutcome.SUCCESS,
                Map.of("appointmentId", appointmentId.toString(), "slotId", slotId.toString())
            );
            return LegacyAvailabilityResponse.success(Map.of("appointmentId", appointmentId));
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
    }

    private AvailabilityException translate(DataAccessException exception) {
        String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (detail.contains("SOLICITUD_NO_PENDIENTE")) {
            return new AvailabilityException(409, "La solicitud ya no está pendiente.");
        }
        if (detail.contains("CUPO_NO_DISPONIBLE")) {
            return new AvailabilityException(409, "El cupo ya no está disponible.");
        }
        if (detail.contains("CUPO_INCOMPATIBLE")) {
            return new AvailabilityException(400, "El cupo no es compatible con la solicitud.");
        }
        if (detail.contains("DERIVACION_NO_PROGRAMABLE")) {
            return new AvailabilityException(409, "La derivación ya no está disponible para programar.");
        }
        if (detail.contains("PACIENTE_CON_CITA_ACTIVA")) {
            return new AvailabilityException(409, "El paciente ya tiene una cita activa en ese horario.");
        }
        return new AvailabilityException(400, "No se pudo asignar la solicitud.");
    }
}

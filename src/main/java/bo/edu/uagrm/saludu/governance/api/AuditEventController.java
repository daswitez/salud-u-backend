package bo.edu.uagrm.saludu.governance.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/audit-events")
public class AuditEventController {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;

    public AuditEventController(JdbcTemplate jdbc, DatabaseActorContext actorContext, AuditWriter auditWriter) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
    }

    @GetMapping
    @PreAuthorize("hasRole('AUDITOR')")
    @Transactional
    public LegacyAvailabilityResponse<List<Map<String, Object>>> list(
        @RequestParam(required = false) LocalDate from, @RequestParam(required = false) LocalDate to,
        @RequestParam(required = false) UUID actorId, @RequestParam(required = false) String action,
        @RequestParam(required = false) String resource, @RequestParam(required = false) String outcome,
        @RequestParam(defaultValue = "100") int limit, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        if ((from != null && to != null && from.isAfter(to)) || limit < 1 || limit > 500) {
            throw new AvailabilityException(400, "Los filtros de auditoría no son válidos.");
        }
        apply(principal);
        try {
            var events = jdbc.query("select * from salud_u.listar_eventos_auditoria(?, ?, ?, ?, ?, ?, ?)", (rs, ignored) -> {
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("id", rs.getObject("id", UUID.class));
                event.put("occurredAt", rs.getObject("ocurrido_en"));
                Map<String, Object> actor = new LinkedHashMap<>();
                actor.put("id", rs.getObject("id_actor", UUID.class));
                actor.put("name", rs.getString("nombre_actor"));
                actor.put("roles", rs.getArray("roles_actor").getArray());
                event.put("actor", actor);
                event.put("action", rs.getString("accion"));
                event.put("resource", rs.getString("tipo_recurso"));
                event.put("resourceId", rs.getObject("id_recurso", UUID.class));
                event.put("outcome", rs.getString("resultado"));
                event.put("context", "Evento operacional " + rs.getString("accion") + " sobre " + rs.getString("tipo_recurso") + ".");
                return event;
            }, from, to, actorId, action, resource, outcome, limit);
            auditWriter.append("AUDIT_EVENTS_READ", "audit_event", null, AuditOutcome.SUCCESS, Map.of("limit", limit));
            return LegacyAvailabilityResponse.success(events);
        } catch (DataAccessException exception) {
            throw new AvailabilityException(400, "No se pudo consultar la auditoría.");
        }
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }
}

package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
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
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/appointment-requests")
public class AppointmentRequestController {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final AuditWriter audit;

    public AppointmentRequestController(JdbcTemplate jdbc, DatabaseActorContext actorContext, AuditWriter audit) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.audit = audit;
    }

    private void applyActor(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    @GetMapping
    @PreAuthorize("hasAnyRole('STUDENT','ADMINISTRATIVE')")
    @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<List<Map<String, Object>>> list(@AuthenticationPrincipal SessionPrincipal principal) {
        applyActor(principal);
        return LegacyAvailabilityResponse.success(jdbc.query("select * from salud_u.listar_mis_solicitudes_cita()", (row, ignored) -> {
            Map<String, Object> request = new LinkedHashMap<>();
            request.put("id", row.getObject("id", UUID.class));
            request.put("appointment_type", row.getString("tipo_cita"));
            request.put("referral_id", row.getObject("id_derivacion", UUID.class));
            request.put("specialty_id", row.getObject("id_especialidad", UUID.class));
            request.put("status", row.getString("estado"));
            request.put("requested_at", row.getObject("solicitado_en"));
            request.put("cancelled_at", row.getObject("cancelado_en"));
            request.put("cancellation_reason", row.getString("motivo_cancelacion"));
            request.put("patient", Map.of("id", row.getObject("id_paciente", UUID.class), "carnet", row.getString("carnet"), "given_names", row.getString("nombre_paciente"), "family_names", ""));

            UUID appointmentId = row.getObject("id_cita", UUID.class);
            if (appointmentId == null) request.put("appointment", null);
            else {
                Map<String, Object> appointment = new LinkedHashMap<>();
                appointment.put("id", appointmentId);
                appointment.put("status", row.getString("estado_cita"));
                appointment.put("scheduled_for", row.getObject("programada_para"));
                appointment.put("doctorName", row.getString("nombre_medico"));
                appointment.put("endsAt", row.getObject("termina_a"));
                appointment.put("checked_in_at", row.getObject("ingreso_registrado_en"));
                appointment.put("cancelled_at", row.getObject("cita_cancelada_en"));
                request.put("appointment", appointment);
            }
            return request;
        }));
    }

    @PostMapping
    @PreAuthorize("hasAnyRole('STUDENT','ADMINISTRATIVE')")
    @Transactional
    public org.springframework.http.ResponseEntity<?> create(@RequestBody Map<String, Object> body, @AuthenticationPrincipal SessionPrincipal principal) {
        String type = String.valueOf(body.getOrDefault("appointmentType", "INITIAL"));
        applyActor(principal);
        if ("REFERRAL".equals(type)) {
            if (!principal.roles().contains("ADMINISTRATIVE")) throw new AvailabilityException(403, "Sólo administración puede programar una derivación.");
            Object raw = body.get("referralId");
            if (!(raw instanceof String referralId) || referralId.isBlank()) throw new AvailabilityException(400, "Selecciona una derivación.");
            if (!(body.get("patientId") instanceof String patientValue) || patientValue.isBlank()) throw new AvailabilityException(400,"Selecciona el estudiante de la derivación.");
            if (body.get("specialtyId") instanceof String value && !value.isBlank()) throw new AvailabilityException(400,"La especialidad se obtiene de la derivación.");
            UUID saved;
            try { saved = jdbc.queryForObject("select salud_u.crear_solicitud_derivacion(?,?)", UUID.class, UUID.fromString(referralId), UUID.fromString(patientValue)); }
            catch(DataAccessException exception) {
                String detail=String.valueOf(exception.getMostSpecificCause().getMessage());
                if(detail.contains("SOLICITUD_DERIVACION_PENDIENTE")) throw new AvailabilityException(409,"Ya existe una solicitud pendiente para esta derivación. Actualiza la agenda para recuperarla.");
                if(detail.contains("DERIVACION_NO_PROGRAMABLE")) throw new AvailabilityException(409,"La derivación no está disponible para este estudiante o ya fue programada.");
                if(detail.contains("PACIENTE_NO_DISPONIBLE")) throw new AvailabilityException(404,"El estudiante no está disponible.");
                throw exception;
            }
            audit.append("SOLICITUD_CITA_DERIVACION_CREADA", "solicitud_cita", saved, AuditOutcome.SUCCESS, Map.of("referralId", referralId));
            return org.springframework.http.ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(Map.of("id", saved)));
        }
        if ("SPECIALTY".equals(type)) {
            if (!principal.roles().contains("ADMINISTRATIVE")) throw new AvailabilityException(403, "Sólo administración puede solicitar una especialidad directa.");
            if (!(body.get("patientId") instanceof String patientValue) || patientValue.isBlank()) throw new AvailabilityException(400, "Selecciona un estudiante para crear la solicitud.");
            if (!(body.get("specialtyId") instanceof String specialtyValue) || specialtyValue.isBlank()) throw new AvailabilityException(400, "Selecciona una especialidad.");
            UUID patientId = UUID.fromString(patientValue);
            UUID specialtyId = UUID.fromString(specialtyValue);
            UUID saved = jdbc.queryForObject("select salud_u.crear_solicitud_especialidad_directa(?, ?)", UUID.class, patientId, specialtyId);
            audit.append("SOLICITUD_CITA_ESPECIALIDAD_CREADA", "solicitud_cita", saved, AuditOutcome.SUCCESS, Map.of("patientId", patientId.toString(), "specialtyId", specialtyId.toString()));
            return org.springframework.http.ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(Map.of("id", saved)));
        }
        if (!"INITIAL".equals(type)) throw new AvailabilityException(400, "Tipo de solicitud no válido.");
        UUID patientId = null;
        if (body.get("patientId") instanceof String value && !value.isBlank()) patientId = UUID.fromString(value);
        if (principal.roles().contains("STUDENT") && patientId != null) throw new AvailabilityException(403, "Una estudiante sólo puede solicitar su propia atención.");
        if (principal.roles().contains("ADMINISTRATIVE") && patientId == null) throw new AvailabilityException(400, "Selecciona un estudiante para crear la solicitud.");
        UUID saved = jdbc.queryForObject("select salud_u.crear_solicitud_inicial(?)", UUID.class, patientId);
        audit.append("SOLICITUD_CITA_CREADA", "solicitud_cita", saved, AuditOutcome.SUCCESS, Map.of());
        return org.springframework.http.ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(Map.of("id", saved)));
    }

    @PatchMapping("/{id}")
    @PreAuthorize("hasAnyRole('STUDENT','ADMINISTRATIVE')")
    @Transactional
    public AppointmentMutationResponse cancel(@PathVariable UUID id, @RequestBody Map<String, Object> body, @AuthenticationPrincipal SessionPrincipal principal) {
        if (!"cancel".equals(body.get("action"))) throw new AvailabilityException(400, "Acción no válida.");
        Object reason = body.get("reason");
        if (reason != null && (!(reason instanceof String text) || text.length() > 300)) {
            throw new AvailabilityException(400, "El motivo debe ser texto de hasta 300 caracteres.");
        }
        applyActor(principal);
        try {
            jdbc.query("select salud_u.cancelar_solicitud_cita(?,?)", row -> { }, id, reason);
        } catch (DataAccessException exception) {
            String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
            if (detail.contains("No autorizado") || detail.contains("Solicitud no encontrada")) {
                throw new AvailabilityException(404, "Solicitud no encontrada.");
            }
            throw new AvailabilityException(409, "La cita asignada ya no puede cancelarse.");
        }
        audit.append("SOLICITUD_CITA_CANCELADA", "solicitud_cita", id, AuditOutcome.SUCCESS, Map.of());
        return AppointmentMutationResponse.success();
    }
}

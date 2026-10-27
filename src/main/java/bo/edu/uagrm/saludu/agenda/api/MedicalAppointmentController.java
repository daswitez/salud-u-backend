package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/medical/appointments")
public class MedicalAppointmentController {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;

    public MedicalAppointmentController(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
    }

    @GetMapping
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
    @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<List<Map<String, Object>>> list(@AuthenticationPrincipal SessionPrincipal principal) {
        apply(principal);
        try {
            return LegacyAvailabilityResponse.success(jdbcTemplate.query("select * from salud_u.listar_mis_citas_medicas()", (rs, row) -> appointment(rs)));
        } catch (DataAccessException exception) { throw translate(exception); }
    }

    /** Una cita del profesional por identificador, sin depender del tope del listado de agenda. */
    @GetMapping("/{appointmentId}")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
    @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<Map<String, Object>> get(@PathVariable UUID appointmentId, @AuthenticationPrincipal SessionPrincipal principal) {
        apply(principal);
        try {
            List<Map<String, Object>> found = jdbcTemplate.query("select * from salud_u.listar_mis_citas_medicas(?)", (rs, row) -> appointment(rs), appointmentId);
            if (found.isEmpty()) throw new AvailabilityException(404, "No se encontró una cita asignada a tu cuenta.");
            return LegacyAvailabilityResponse.success(found.get(0));
        } catch (DataAccessException exception) { throw translate(exception); }
    }

    private static Map<String, Object> appointment(java.sql.ResultSet rs) throws java.sql.SQLException {
        Map<String, Object> patient = new LinkedHashMap<>();
        patient.put("id", rs.getObject("id_paciente", UUID.class));
        patient.put("carnet", rs.getString("carnet"));
        patient.put("registrationCode", rs.getString("codigo_registro"));
        patient.put("fullName", (rs.getString("nombres") + " " + rs.getString("apellidos")).trim());
        patient.put("birthDate", rs.getObject("fecha_nacimiento", java.time.LocalDate.class));
        patient.put("phone", rs.getString("telefono"));
        patient.put("email", rs.getString("email"));
        Map<String, Object> appointment = new LinkedHashMap<>();
        appointment.put("id", rs.getObject("id", UUID.class));
        appointment.put("appointmentType", rs.getString("tipo_cita"));
        appointment.put("status", rs.getString("estado_cita"));
        appointment.put("scheduledFor", rs.getObject("programada_para", OffsetDateTime.class));
        appointment.put("endsAt", rs.getObject("termina_a", OffsetDateTime.class));
        appointment.put("checkedInAt", rs.getObject("ingreso_registrado_en", OffsetDateTime.class));
        appointment.put("specialty", rs.getString("nombre_especialidad") == null ? "Revisión estudiantil" : rs.getString("nombre_especialidad"));
        appointment.put("specialtyCode", rs.getString("codigo_especialidad"));
        appointment.put("patient", patient);
        UUID encounterId = rs.getObject("id_encuentro", UUID.class);
        appointment.put("encounter", encounterId == null ? null : Map.of("id", encounterId, "status", rs.getString("estado_encuentro")));
        return appointment;
    }

    @PostMapping("/{appointmentId}/start")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
    @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<Map<String, Object>>> start(
        @PathVariable UUID appointmentId, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        apply(principal);
        try {
            var result = jdbcTemplate.queryForMap("select * from salud_u.abrir_encuentro_borrador(?)", appointmentId);
            boolean created = Boolean.TRUE.equals(result.get("creado"));
            UUID encounterId = (UUID) result.get("id_encuentro");
            String status = (String) result.get("estado");
            if (created) auditWriter.append("ENCUENTRO_BORRADOR_CREADO", "encuentro_clinico", encounterId, AuditOutcome.SUCCESS, Map.of("idCita", appointmentId.toString()));
            return ResponseEntity.status(created ? 201 : 200).body(LegacyAvailabilityResponse.success(Map.of("encounterId", encounterId, "status", status)));
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    private AvailabilityException translate(DataAccessException exception) {
        String detail = exception.getMostSpecificCause().getMessage();
        if (detail != null && detail.contains("CITA_AJENA_O_INEXISTENTE")) return new AvailabilityException(404, "La cita no pertenece a este profesional.");
        if (detail != null && detail.contains("CITA_NO_INICIABLE")) return new AvailabilityException(409, "Esta cita ya no puede iniciarse.");
        if (detail != null && detail.contains("MEDICO_NO_AUTORIZADO")) return new AvailabilityException(403, "No tiene permiso para iniciar esta cita.");
        if (detail != null && detail.contains("ESPECIALIDAD_AJENA_O_INACTIVA")) return new AvailabilityException(403, "La especialidad no está activa para este profesional.");
        if (detail != null && detail.contains("No existe una ficha de personal activa")) return new AvailabilityException(404, "Esta cuenta no tiene una ficha de personal activa.");
        return new AvailabilityException(400, "No se pudo iniciar el encuentro clínico.");
    }
}

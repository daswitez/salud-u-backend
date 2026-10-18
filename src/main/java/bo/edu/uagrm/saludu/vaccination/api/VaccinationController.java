package bo.edu.uagrm.saludu.vaccination.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.time.LocalDate;
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
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/vaccinations")
public class VaccinationController {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;

    public VaccinationController(JdbcTemplate jdbc, DatabaseActorContext actorContext) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
    }

    @PostMapping
    @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REVIEW_DOCTOR')")
    @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<Map<String, Object>>> applyDose(
        @RequestBody VaccinationApplicationRequest request,
        @AuthenticationPrincipal SessionPrincipal principal
    ) {
        if (request == null || request.patientId() == null || request.vaccineId() == null || request.doseNumber() == null || request.appliedOn() == null || request.lot() == null) {
            throw new AvailabilityException(400, "Los datos de la dosis son obligatorios.");
        }
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try {
            Map<String, Object> data = jdbc.queryForObject(
                "select * from salud_u.registrar_dosis_vacuna(?, ?, ?, ?, ?, ?, ?)",
                (rs, ignored) -> {
                    Map<String, Object> result = new LinkedHashMap<>();
                    result.put("id", rs.getObject("id", UUID.class));
                    result.put("intervalWarning", rs.getBoolean("advertencia_intervalo"));
                    result.put("applicatorStaffId", rs.getObject("id_personal_aplicador", UUID.class));
                    result.put("registeredBy", rs.getObject("id_registrado_por", UUID.class));
                    result.put("appliedOn", rs.getObject("fecha_aplicacion", LocalDate.class));
                    return result;
                },
                request.patientId(), request.vaccineId(), request.doseNumber(), request.appliedOn(), request.lot(), request.applicatorStaffId(), request.intervalOverrideJustification()
            );
            return ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(data));
        } catch (DataAccessException exception) {
            throw doseException(exception);
        }
    }

    private AvailabilityException doseException(DataAccessException exception) {
        String message = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (message.contains("DOSIS_VACUNA_APLICADA_UNICA") || message.contains("duplicate key")) return new AvailabilityException(409, "Esta dosis ya fue registrada para el paciente.");
        if (message.contains("REGISTRO_VACUNA_NO_AUTORIZADO") || message.contains("APLICADOR_INVALIDO") || message.contains("APLICADOR_DISTINTO_AL_ACTOR")) return new AvailabilityException(403, "No tiene permiso para registrar esta dosis.");
        if (message.contains("PACIENTE_NO_ENCONTRADO")) return new AvailabilityException(404, "El paciente no existe.");
        return new AvailabilityException(400, "La dosis no cumple las reglas de vacunación.");
    }

    public record VaccinationApplicationRequest(UUID patientId, UUID vaccineId, Integer doseNumber, LocalDate appliedOn, String lot, UUID applicatorStaffId, String intervalOverrideJustification) { }
}

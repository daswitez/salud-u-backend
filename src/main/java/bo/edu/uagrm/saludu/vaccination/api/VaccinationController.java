package bo.edu.uagrm.saludu.vaccination.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.ObjectMapper;
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
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/vaccinations")
public class VaccinationController {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final ObjectMapper json;

    public VaccinationController(JdbcTemplate jdbc, DatabaseActorContext actorContext, ObjectMapper json) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.json = json;
    }

    @GetMapping("/context")
    @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REVIEW_DOCTOR')")
    @Transactional
    public LegacyAvailabilityResponse<Object> context(@RequestParam(required = false) UUID patientId, @AuthenticationPrincipal SessionPrincipal principal) {
        if (patientId == null) throw new AvailabilityException(400, "El paciente es obligatorio.");
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        String data;
        try {
            data = jdbc.queryForObject("select salud_u.contexto_registro_vacunacion(?)::text", String.class, patientId);
        } catch (DataAccessException exception) {
            throw doseException(exception);
        }
        try {
            return LegacyAvailabilityResponse.success(json.readValue(data, Object.class));
        } catch (Exception exception) {
            throw new IllegalStateException("No se pudo leer el registro de vacunación.", exception);
        }
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
        if (message.contains("dosis_vacuna_aplicada_unica") || message.contains("duplicate key")) return new AvailabilityException(409, "Esta dosis ya fue registrada para el paciente.");
        if (message.contains("INTERVALO_INSUFICIENTE_REQUIERE_JUSTIFICACION")) return new AvailabilityException(422, "La fecha no cumple el intervalo mínimo desde la dosis anterior. Escribe una justificación para registrarla.");
        if (message.contains("DOSIS_FUERA_DE_ORDEN")) return new AvailabilityException(409, "Primero debe registrarse la dosis anterior de esta vacuna.");
        if (message.contains("VACUNA_O_DOSIS_INACTIVA")) return new AvailabilityException(409, "La vacuna está inactiva o esa dosis no pertenece a su esquema vigente.");
        if (message.contains("FECHA_DOSIS_FUTURA")) return new AvailabilityException(400, "La fecha de aplicación no puede ser posterior a hoy (hora de Bolivia).");
        if (message.contains("FECHA_DOSIS_INVALIDA")) return new AvailabilityException(400, "La fecha no puede ser anterior a la dosis previa.");
        if (message.contains("APLICADOR_INVALIDO")) return new AvailabilityException(400, "El aplicador debe ser un médico de revisión activo.");
        if (message.contains("justificacion_intervalo_requerida")) return new AvailabilityException(400, "La justificación debe tener hasta 500 caracteres.");
        if (message.contains("REGISTRO_VACUNA_NO_AUTORIZADO") || message.contains("APLICADOR_DISTINTO_AL_ACTOR")) return new AvailabilityException(403, "No tiene permiso para registrar esta dosis.");
        if (message.contains("PACIENTE_NO_ENCONTRADO") || message.contains("PACIENTE_AJENO_O_INEXISTENTE")) return new AvailabilityException(404, "El paciente no existe o no está asignado a tu atención.");
        return new AvailabilityException(400, "La dosis no cumple las reglas de vacunación.");
    }

    public record VaccinationApplicationRequest(UUID patientId, UUID vaccineId, Integer doseNumber, LocalDate appliedOn, String lot, UUID applicatorStaffId, String intervalOverrideJustification) { }
}

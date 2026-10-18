package bo.edu.uagrm.saludu.vaccination.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
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
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/vaccines")
public class VaccineController {
    private final JdbcTemplate jdbc; private final DatabaseActorContext actorContext; private final ObjectMapper json;
    public VaccineController(JdbcTemplate jdbc, DatabaseActorContext actorContext, ObjectMapper json) { this.jdbc = jdbc; this.actorContext = actorContext; this.json = json; }

    @GetMapping @PreAuthorize("hasRole('ADMINISTRATIVE')") @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<List<Map<String, Object>>> list(@RequestParam(defaultValue = "false") boolean includeInactive, @AuthenticationPrincipal SessionPrincipal principal) {
        apply(principal);
        return LegacyAvailabilityResponse.success(jdbc.query("select * from salud_u.listar_vacunas(?)", (rs, ignored) -> { try { return Map.of("id", rs.getObject("id", UUID.class), "code", rs.getString("codigo"), "name", rs.getString("nombre"), "active", rs.getBoolean("activo"), "schemaVersion", rs.getInt("version_esquema"), "doses", json.readValue(rs.getString("dosis"), Object.class)); } catch (Exception exception) { throw new IllegalStateException("No se pudo leer el esquema de vacuna.", exception); } }, includeInactive));
    }
    @PostMapping @PreAuthorize("hasRole('ADMINISTRATIVE')") @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<Map<String, UUID>>> create(@RequestBody VaccineRequest request, @AuthenticationPrincipal SessionPrincipal principal) { return ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(Map.of("id", save(null, request, principal)))); }
    @PutMapping("/{id}") @PreAuthorize("hasRole('ADMINISTRATIVE')") @Transactional
    public LegacyAvailabilityResponse<Map<String, UUID>> update(@PathVariable UUID id, @RequestBody VaccineRequest request, @AuthenticationPrincipal SessionPrincipal principal) { return LegacyAvailabilityResponse.success(Map.of("id", save(id, request, principal))); }
    private UUID save(UUID id, VaccineRequest request, SessionPrincipal principal) {
        if (request == null || request.code() == null || request.name() == null || request.active() == null || request.doses() == null) throw new AvailabilityException(400, "El esquema de vacuna es obligatorio.");
        apply(principal);
        try { return jdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(?, ?, ?, ?, cast(? as jsonb))", UUID.class, id, request.code(), request.name(), request.active(), json.writeValueAsString(request.doses())); }
        catch (DataAccessException exception) { throw new AvailabilityException(400, "El esquema de vacuna no es válido."); }
        catch (Exception exception) { throw new AvailabilityException(400, "El esquema de vacuna no es válido."); }
    }
    private void apply(SessionPrincipal principal) { actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles()))); }
    public record VaccineRequest(String code, String name, Boolean active, List<DoseRequest> doses) {}
    public record DoseRequest(Integer doseNumber, Integer minimumIntervalDays) {}
}

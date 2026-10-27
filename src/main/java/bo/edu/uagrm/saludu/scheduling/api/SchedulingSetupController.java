package bo.edu.uagrm.saludu.scheduling.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.scheduling.application.AcademicPeriod;
import bo.edu.uagrm.saludu.scheduling.application.InitialSchedulingValue;
import bo.edu.uagrm.saludu.scheduling.application.SchedulingSetupService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.List;
import java.util.Set;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
@PreAuthorize("hasRole('ADMINISTRATIVE')")
public class SchedulingSetupController {
    private static final Set<String> PERIOD_FIELDS = Set.of("name", "type", "startDate", "endDate");
    private static final Set<String> VALUE_FIELDS = Set.of("specialtyId", "periodType", "expectedDailyDemand", "expectedAttendance", "appointmentWeight");
    private final SchedulingSetupService setup;
    private final ObjectMapper json;

    public SchedulingSetupController(SchedulingSetupService setup, ObjectMapper json) { this.setup = setup; this.json = json; }

    @GetMapping("/api/academic-periods")
    public ResponseEntity<LegacyAvailabilityResponse<List<AcademicPeriod>>> periods(@AuthenticationPrincipal SessionPrincipal principal) {
        return response(200, setup.periods(principal));
    }

    @PostMapping("/api/academic-periods")
    public ResponseEntity<LegacyAvailabilityResponse<AcademicPeriod>> registerPeriod(@RequestBody JsonNode body,
        @AuthenticationPrincipal SessionPrincipal principal) {
        if (!onlyFields(body, PERIOD_FIELDS) || !body.path("name").isTextual() || !body.path("type").isTextual()) throw invalidPeriod();
        return response(201, setup.registerPeriod(principal, body.path("name").textValue(), body.path("type").textValue(),
            date(body.path("startDate")), date(body.path("endDate"))));
    }

    @GetMapping("/api/scheduling/initial-values")
    public ResponseEntity<LegacyAvailabilityResponse<List<InitialSchedulingValue>>> initialValues(@AuthenticationPrincipal SessionPrincipal principal) {
        return response(200, setup.initialValues(principal));
    }

    /** Recibe {"values": [...]} con las filas a guardar; las no enviadas conservan su valor. Devuelve la tabla completa. */
    @PutMapping("/api/scheduling/initial-values")
    public ResponseEntity<LegacyAvailabilityResponse<List<InitialSchedulingValue>>> saveInitialValues(@RequestBody JsonNode body,
        @AuthenticationPrincipal SessionPrincipal principal) {
        if (!onlyFields(body, Set.of("values")) || !body.path("values").isArray() || body.path("values").isEmpty()) throw invalidValues();
        ArrayNode values = json.createArrayNode();
        for (JsonNode item : body.path("values")) {
            JsonNode specialty = item.path("specialtyId"), demand = item.path("expectedDailyDemand");
            if (!onlyFields(item, VALUE_FIELDS) || !item.path("periodType").isTextual()
                || !(specialty.isMissingNode() || specialty.isNull() || specialty.isTextual())
                || !(demand.isMissingNode() || demand.isNull() || demand.isNumber())
                || !item.path("expectedAttendance").isNumber() || !item.path("appointmentWeight").isIntegralNumber()) throw invalidValues();
            ObjectNode row = values.addObject();
            row.set("id_especialidad", specialty.isTextual() ? specialty : null);
            row.set("tipo_periodo", item.path("periodType"));
            row.set("demanda_diaria_esperada", demand.isNumber() ? demand : null);
            row.set("asistencia_esperada", item.path("expectedAttendance"));
            row.set("peso_citas", item.path("appointmentWeight"));
        }
        return response(200, setup.saveInitialValues(principal, values.toString()));
    }

    private static boolean onlyFields(JsonNode body, Set<String> allowed) {
        if (body == null || !body.isObject()) return false;
        for (var names = body.fieldNames(); names.hasNext(); ) if (!allowed.contains(names.next())) return false;
        return true;
    }

    private static LocalDate date(JsonNode node) {
        if (!node.isTextual()) throw invalidPeriod();
        try { return LocalDate.parse(node.textValue()); } catch (DateTimeParseException exception) { throw invalidPeriod(); }
    }

    private static AvailabilityException invalidPeriod() { return new AvailabilityException(400, "Revisa el nombre, el tipo y las fechas del período."); }
    private static AvailabilityException invalidValues() { return new AvailabilityException(400, "Los valores iniciales no son válidos."); }
    private static <T> ResponseEntity<LegacyAvailabilityResponse<T>> response(int status, T data) {
        return ResponseEntity.status(status).header("Cache-Control", "no-store, private").body(LegacyAvailabilityResponse.success(data));
    }
}

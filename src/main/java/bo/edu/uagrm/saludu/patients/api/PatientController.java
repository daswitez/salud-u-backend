package bo.edu.uagrm.saludu.patients.api;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.patients.application.InvalidPatientException;
import bo.edu.uagrm.saludu.patients.application.PatientService;
import bo.edu.uagrm.saludu.patients.application.PatientSummary;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/patients")
@PreAuthorize("hasRole('ADMINISTRATIVE')")
public class PatientController {
    private final PatientService patientService;

    public PatientController(PatientService patientService) {
        this.patientService = patientService;
    }

    @GetMapping
    public LegacyPatientResponse<List<PatientSummary>> list(
        @RequestParam(name = "query", required = false) String query, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        return LegacyPatientResponse.success(patientService.list(principal, query));
    }

    @PostMapping
    public ResponseEntity<LegacyPatientResponse<java.util.Map<String, UUID>>> create(
        @RequestBody PatientRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        PatientService.PatientCommand command = commandForCreate(request);
        UUID id = patientService.create(principal, command);
        return ResponseEntity.status(201).body(LegacyPatientResponse.success(java.util.Map.of("id", id)));
    }

    @GetMapping("/{patientId}")
    public LegacyPatientResponse<PatientSummary> get(@PathVariable UUID patientId, @AuthenticationPrincipal SessionPrincipal principal) {
        return LegacyPatientResponse.success(patientService.get(principal, patientId).orElseThrow(bo.edu.uagrm.saludu.patients.application.PatientNotFoundException::new));
    }

    @PatchMapping("/{patientId}")
    public LegacyPatientResponse<java.util.Map<String, UUID>> update(
        @PathVariable UUID patientId, @RequestBody PatientRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        PatientSummary current = patientService.get(principal, patientId).orElseThrow(bo.edu.uagrm.saludu.patients.application.PatientNotFoundException::new);
        UUID id = patientService.update(principal, patientId, commandForUpdate(request, current));
        return LegacyPatientResponse.success(java.util.Map.of("id", id));
    }

    private static PatientService.PatientCommand commandForCreate(PatientRequest request) {
        Names names = splitRequiredName(request.fullName());
        if (blank(request.carnet()) || blank(request.registrationCode()) || request.careerId() == null || blank(request.academicPeriod()) || request.enrollmentStart() == null) {
            throw new InvalidPatientException("Completa nombre, carnet, código, carrera y período académico.");
        }
        return new PatientService.PatientCommand(request.carnet(), request.registrationCode(), names.givenNames(), names.familyNames(), request.birthDate(), request.phone(), request.email(), request.careerId(), request.academicPeriod(), request.enrollmentStart());
    }

    private static PatientService.PatientCommand commandForUpdate(PatientRequest request, PatientSummary current) {
        Names names = blank(request.fullName()) ? splitExistingName(current.fullName()) : splitRequiredName(request.fullName());
        return new PatientService.PatientCommand(
            blank(request.carnet()) ? current.carnet() : request.carnet(),
            blank(request.registrationCode()) ? current.registrationCode() : request.registrationCode(),
            names.givenNames(), names.familyNames(), request.birthDate() == null ? current.birthDate() : request.birthDate(),
            request.phone(), request.email(), request.careerId(), request.academicPeriod(), request.enrollmentStart()
        );
    }

    private static Names splitRequiredName(String fullName) {
        if (blank(fullName)) throw new InvalidPatientException("Completa nombre, carnet, código, carrera y período académico.");
        return splitExistingName(fullName);
    }

    private static Names splitExistingName(String value) {
        String[] parts = value.trim().split("\\s+");
        if (parts.length < 2) throw new InvalidPatientException("El nombre completo debe incluir nombres y apellidos.");
        int middle = (int) Math.ceil(parts.length / 2.0);
        return new Names(String.join(" ", java.util.Arrays.copyOfRange(parts, 0, middle)), String.join(" ", java.util.Arrays.copyOfRange(parts, middle, parts.length)));
    }

    private static boolean blank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private record Names(String givenNames, String familyNames) {
    }
}

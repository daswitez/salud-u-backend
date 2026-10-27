package bo.edu.uagrm.saludu.patients.api;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.patients.application.ConsentAnswer;
import bo.edu.uagrm.saludu.patients.application.ConsentService;
import bo.edu.uagrm.saludu.patients.application.EmergencyContact;
import bo.edu.uagrm.saludu.patients.application.InvalidPatientException;
import bo.edu.uagrm.saludu.patients.application.PatientDetail;
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
    /** A-01: códigos de API del dominio sexo; ausente significa "no cambia" (al crear queda sin registrar). */
    private static final java.util.Set<String> SEXES = java.util.Set.of("FEMALE", "MALE", "NOT_RECORDED");
    private final PatientService patientService;
    private final ConsentService consentService;

    public PatientController(PatientService patientService, ConsentService consentService) {
        this.patientService = patientService;
        this.consentService = consentService;
    }

    @GetMapping
    public LegacyPatientResponse<List<PatientSummary>> list(
        @RequestParam(name = "query", required = false) String query, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        return LegacyPatientResponse.success(patientService.list(principal, query));
    }

    /** Paciente, contacto y respuesta de consentimiento en una sola transacción: si algo falla, no se guarda nada. */
    @PostMapping
    @org.springframework.transaction.annotation.Transactional
    public ResponseEntity<LegacyPatientResponse<java.util.Map<String, UUID>>> create(
        @RequestBody PatientRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        PatientService.PatientCommand command = commandForCreate(request);
        PatientService.ContactChange contact = contact(request.emergencyContact());
        ConsentAnswer consents = request.consents() == null ? null : request.consents().validated();
        // Al crear, un null explícito es lo mismo que no enviarlo: no hay contacto que eliminar.
        UUID id = patientService.create(principal, command, contact.value() == null ? PatientService.ContactChange.UNCHANGED : contact);
        if (consents != null) consentService.saveForPatient(principal, id, consents);
        return ResponseEntity.status(201).body(LegacyPatientResponse.success(java.util.Map.of("id", id)));
    }

    @GetMapping("/{patientId}")
    public LegacyPatientResponse<PatientDetail> get(@PathVariable UUID patientId, @AuthenticationPrincipal SessionPrincipal principal) {
        return LegacyPatientResponse.success(patientService.detail(principal, patientId).orElseThrow(bo.edu.uagrm.saludu.patients.application.PatientNotFoundException::new));
    }

    @PatchMapping("/{patientId}")
    public LegacyPatientResponse<java.util.Map<String, UUID>> update(
        @PathVariable UUID patientId, @RequestBody PatientRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        PatientSummary current = patientService.get(principal, patientId).orElseThrow(bo.edu.uagrm.saludu.patients.application.PatientNotFoundException::new);
        UUID id = patientService.update(principal, patientId, commandForUpdate(request, current), contact(request.emergencyContact()));
        return LegacyPatientResponse.success(java.util.Map.of("id", id));
    }

    private static PatientService.PatientCommand commandForCreate(PatientRequest request) {
        Names names = splitRequiredName(request.fullName());
        if (blank(request.carnet()) || blank(request.registrationCode()) || request.careerId() == null || blank(request.academicPeriod()) || request.enrollmentStart() == null) {
            throw new InvalidPatientException("Completa nombre, carnet, código, carrera y período académico.");
        }
        return new PatientService.PatientCommand(request.carnet(), request.registrationCode(), names.givenNames(), names.familyNames(), request.birthDate(), request.phone(), request.email(), request.careerId(), request.academicPeriod(), request.enrollmentStart(), sex(request.sex()));
    }

    private static PatientService.PatientCommand commandForUpdate(PatientRequest request, PatientSummary current) {
        Names names = blank(request.fullName()) ? splitExistingName(current.fullName()) : splitRequiredName(request.fullName());
        return new PatientService.PatientCommand(
            blank(request.carnet()) ? current.carnet() : request.carnet(),
            blank(request.registrationCode()) ? current.registrationCode() : request.registrationCode(),
            names.givenNames(), names.familyNames(), request.birthDate() == null ? current.birthDate() : request.birthDate(),
            request.phone(), request.email(), request.careerId(), request.academicPeriod(), request.enrollmentStart(),
            request.sex() == null ? current.sex() : sex(request.sex())
        );
    }

    private static PatientService.ContactChange contact(com.fasterxml.jackson.databind.JsonNode node) {
        if (node == null) return PatientService.ContactChange.UNCHANGED;
        return new PatientService.ContactChange(true, node.isNull() ? null : EmergencyContact.parse(node));
    }

    private static String sex(String value) {
        if (value != null && !SEXES.contains(value)) throw new InvalidPatientException("El sexo debe ser FEMALE, MALE o NOT_RECORDED.");
        return value;
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

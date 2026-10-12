package bo.edu.uagrm.saludu.patients.application;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class PatientService {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;

    public PatientService(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
    }

    @Transactional(readOnly = true)
    public List<PatientSummary> list(SessionPrincipal principal, String query) {
        apply(principal);
        return jdbcTemplate.query("select * from salud_u.listar_pacientes(?)", (resultSet, rowNumber) -> summary(resultSet), query);
    }

    @Transactional(readOnly = true)
    public Optional<PatientSummary> get(SessionPrincipal principal, UUID patientId) {
        apply(principal);
        return jdbcTemplate.query("select * from salud_u.obtener_paciente(?)", (resultSet, rowNumber) -> summary(resultSet), patientId).stream().findFirst();
    }

    @Transactional
    public UUID create(SessionPrincipal principal, PatientCommand command) {
        return save(principal, null, command, "PATIENT_CREATED");
    }

    @Transactional
    public UUID update(SessionPrincipal principal, UUID patientId, PatientCommand command) {
        return save(principal, patientId, command, "PATIENT_UPDATED");
    }

    private UUID save(SessionPrincipal principal, UUID patientId, PatientCommand command, String auditAction) {
        apply(principal);
        try {
            List<SaveResult> results = jdbcTemplate.query(
                "select * from salud_u.guardar_paciente(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (resultSet, rowNumber) -> new SaveResult(resultSet.getString("codigo_resultado"), resultSet.getObject("id_paciente", UUID.class)),
                patientId, command.carnet(), command.registrationCode(), command.givenNames(), command.familyNames(),
                command.birthDate(), command.phone(), command.email(), command.careerId(), command.academicPeriod(), command.enrollmentStart()
            );
            if (results.size() != 1 || results.getFirst().patientId() == null) {
                throw resultException(results.isEmpty() ? "INVALID" : results.getFirst().resultCode());
            }
            UUID savedId = results.getFirst().patientId();
            auditWriter.append(auditAction, "patient", savedId, AuditOutcome.SUCCESS, Map.of("hasEnrollment", command.careerId() != null));
            return savedId;
        } catch (DuplicateKeyException exception) {
            throw new DuplicatePatientIdentifierException();
        }
    }

    private static RuntimeException resultException(String resultCode) {
        return switch (resultCode) {
            case "NOT_FOUND" -> new PatientNotFoundException();
            case "DUPLICATE_CARNET", "DUPLICATE_REGISTRATION", "DUPLICATE_IDENTIFIER" -> new DuplicatePatientIdentifierException();
            default -> new InvalidPatientException("Los datos del paciente no son válidos.");
        };
    }

    private static PatientSummary summary(ResultSet resultSet) throws SQLException {
        UUID careerId = resultSet.getObject("id_carrera", UUID.class);
        UUID enrollmentId = resultSet.getObject("enrollment_id", UUID.class);
        return new PatientSummary(
            resultSet.getObject("id_paciente", UUID.class), resultSet.getString("carnet"), resultSet.getString("codigo_registro"),
            (resultSet.getString("nombres") + " " + resultSet.getString("apellidos")).trim(),
            resultSet.getObject("fecha_nacimiento", LocalDate.class), resultSet.getString("telefono"), resultSet.getString("email"),
            resultSet.getString("estado_academico"), resultSet.getObject("creado_en", OffsetDateTime.class).toInstant(), resultSet.getObject("actualizado_en", OffsetDateTime.class).toInstant(),
            careerId == null ? null : new PatientSummary.Career(careerId, resultSet.getString("career_code"), resultSet.getString("career_name")),
            enrollmentId == null ? null : new PatientSummary.Enrollment(enrollmentId, resultSet.getString("periodo_academico"), resultSet.getObject("enrollment_started_on", LocalDate.class), resultSet.getString("enrollment_status"))
        );
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), java.util.Set.copyOf(principal.roles())));
    }

    public record PatientCommand(
        String carnet, String registrationCode, String givenNames, String familyNames, LocalDate birthDate,
        String phone, String email, UUID careerId, String academicPeriod, LocalDate enrollmentStart
    ) {
    }

    private record SaveResult(String resultCode, UUID patientId) {
    }
}

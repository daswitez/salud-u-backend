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
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.dao.DataAccessException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class PatientService {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;
    private final ObjectMapper json;

    public PatientService(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter, ObjectMapper json) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
        this.json = json;
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

    /** A-02: los datos de siempre más el contacto de emergencia. */
    @Transactional(readOnly = true)
    public Optional<PatientDetail> detail(SessionPrincipal principal, UUID patientId) {
        return get(principal, patientId).map(patient -> new PatientDetail(patient,
            EmergencyContact.fromJson(read(jdbcTemplate.queryForObject("select salud_u.obtener_contacto_emergencia(?)::text", String.class, patientId)))));
    }

    @Transactional
    public UUID create(SessionPrincipal principal, PatientCommand command) {
        return create(principal, command, ContactChange.UNCHANGED);
    }

    @Transactional
    public UUID create(SessionPrincipal principal, PatientCommand command, ContactChange contact) {
        return save(principal, null, command, "PACIENTE_CREADO", contact);
    }

    @Transactional
    public UUID update(SessionPrincipal principal, UUID patientId, PatientCommand command) {
        return update(principal, patientId, command, ContactChange.UNCHANGED);
    }

    @Transactional
    public UUID update(SessionPrincipal principal, UUID patientId, PatientCommand command, ContactChange contact) {
        return save(principal, patientId, command, "PACIENTE_ACTUALIZADO", contact);
    }

    /** A-02: contacto de la ficha propia del estudiante. */
    @Transactional(readOnly = true)
    public EmergencyContact myEmergencyContact(SessionPrincipal principal) {
        apply(principal);
        try {
            return EmergencyContact.fromJson(read(jdbcTemplate.queryForObject("select salud_u.obtener_mi_contacto_emergencia()::text", String.class)));
        } catch (DataAccessException exception) {
            throw contactException(exception);
        }
    }

    @Transactional
    public EmergencyContact saveMyEmergencyContact(SessionPrincipal principal, EmergencyContact contact) {
        apply(principal);
        try {
            return EmergencyContact.fromJson(read(jdbcTemplate.queryForObject("select salud_u.guardar_mi_contacto_emergencia(?, ?, ?)::text", String.class,
                contact.fullName(), contact.relationship(), contact.phone())));
        } catch (DataAccessException exception) {
            throw contactException(exception);
        }
    }

    private UUID save(SessionPrincipal principal, UUID patientId, PatientCommand command, String auditAction, ContactChange contact) {
        apply(principal);
        try {
            List<SaveResult> results = jdbcTemplate.query(
                "select * from salud_u.guardar_paciente(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (resultSet, rowNumber) -> new SaveResult(resultSet.getString("codigo_resultado"), resultSet.getObject("id_paciente", UUID.class)),
                patientId, command.carnet(), command.registrationCode(), command.givenNames(), command.familyNames(),
                command.birthDate(), command.phone(), command.email(), command.careerId(), command.academicPeriod(), command.enrollmentStart(), command.sex()
            );
            if (results.size() != 1 || results.getFirst().patientId() == null) {
                throw resultException(results.isEmpty() ? "INVALIDO" : results.getFirst().resultCode());
            }
            UUID savedId = results.getFirst().patientId();
            auditWriter.append(auditAction, "paciente", savedId, AuditOutcome.SUCCESS, Map.of("hasEnrollment", command.careerId() != null));
            applyContact(savedId, contact);
            return savedId;
        } catch (DuplicateKeyException exception) {
            throw new DuplicatePatientIdentifierException();
        }
    }

    /** Misma transacción que el paciente: si el contacto es inválido, tampoco se guarda el paciente. */
    private void applyContact(UUID patientId, ContactChange contact) {
        if (!contact.present()) return;
        try {
            if (contact.value() == null) jdbcTemplate.queryForObject("select salud_u.eliminar_contacto_emergencia(?)::text", String.class, patientId);
            else jdbcTemplate.queryForObject("select salud_u.guardar_contacto_emergencia(?, ?, ?, ?)::text", String.class, patientId,
                contact.value().fullName(), contact.value().relationship(), contact.value().phone());
        } catch (DataAccessException exception) {
            throw contactException(exception);
        }
    }

    private static RuntimeException contactException(DataAccessException exception) {
        String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (detail.contains("CONTACTO_EMERGENCIA_INVALIDO")) return new InvalidPatientException("El contacto de emergencia no es válido.");
        if (detail.contains("PACIENTE_PROPIO_NO_ENCONTRADO") || detail.contains("PACIENTE_NO_ENCONTRADO")) return new PatientNotFoundException();
        return exception;
    }

    private JsonNode read(String value) {
        try { return value == null ? null : json.readTree(value); }
        catch (JsonProcessingException exception) { throw new IllegalStateException("Contacto de emergencia ilegible.", exception); }
    }

    private static RuntimeException resultException(String resultCode) {
        return switch (resultCode) {
            case "NO_ENCONTRADO" -> new PatientNotFoundException();
            case "CARNET_DUPLICADO", "REGISTRO_DUPLICADO", "IDENTIFICADOR_DUPLICADO" -> new DuplicatePatientIdentifierException();
            default -> new InvalidPatientException("Los datos del paciente no son válidos.");
        };
    }

    private static PatientSummary summary(ResultSet resultSet) throws SQLException {
        UUID careerId = resultSet.getObject("id_carrera", UUID.class);
        // Los nombres son los del contrato SQL de listar_pacientes/obtener_paciente.
        UUID enrollmentId = resultSet.getObject("inscripcion_id", UUID.class);
        return new PatientSummary(
            resultSet.getObject("id_paciente", UUID.class), resultSet.getString("carnet"), resultSet.getString("codigo_registro"),
            (resultSet.getString("nombres") + " " + resultSet.getString("apellidos")).trim(),
            resultSet.getObject("fecha_nacimiento", LocalDate.class), resultSet.getString("telefono"), resultSet.getString("correo"),
            resultSet.getString("estado_academico"), resultSet.getObject("creado_en", OffsetDateTime.class).toInstant(), resultSet.getObject("actualizado_en", OffsetDateTime.class).toInstant(),
            careerId == null ? null : new PatientSummary.Career(careerId, resultSet.getString("codigo_carrera"), resultSet.getString("nombre_carrera")),
            enrollmentId == null ? null : new PatientSummary.Enrollment(enrollmentId, resultSet.getString("periodo_academico"), resultSet.getObject("inscripcion_iniciada_en", LocalDate.class), resultSet.getString("estado_inscripcion")),
            resultSet.getString("sexo")
        );
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), java.util.Set.copyOf(principal.roles())));
    }

    public record PatientCommand(
        String carnet, String registrationCode, String givenNames, String familyNames, LocalDate birthDate,
        String phone, String email, UUID careerId, String academicPeriod, LocalDate enrollmentStart, String sex
    ) {
    }

    private record SaveResult(String resultCode, UUID patientId) {
    }

    /** A-02: present=false no toca el contacto; present con value=null lo elimina. */
    public record ContactChange(boolean present, EmergencyContact value) {
        public static final ContactChange UNCHANGED = new ContactChange(false, null);
    }
}

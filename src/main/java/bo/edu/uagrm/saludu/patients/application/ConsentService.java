package bo.edu.uagrm.saludu.patients.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Set;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * A-03: términos de uso y consentimiento para investigación. La base aplica la regla de cada rol y audita
 * CONSENTIMIENTO_REGISTRADO con su vía (PORTAL o ADMINISTRACION).
 *
 * <p>Puesta en marcha en tres pasos: mientras {@code salud-u.consents.required} sea false, una respuesta que llega se
 * registra pero no se exige; con true, crear una solicitud con la respuesta pendiente responde 422.
 */
@Service
public class ConsentService {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final ObjectMapper json;
    private final boolean required;

    public ConsentService(JdbcTemplate jdbc, DatabaseActorContext actorContext, ObjectMapper json,
        @Value("${salud-u.consents.required:false}") boolean required) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.json = json;
        this.required = required;
    }

    @Transactional(readOnly = true)
    public Object mine(SessionPrincipal principal) {
        return query(principal, "select salud_u.obtener_mis_consentimientos()::text");
    }

    @Transactional
    public Object saveMine(SessionPrincipal principal, ConsentAnswer answer) {
        ConsentAnswer valid = answer == null ? new ConsentAnswer(null, null, null, null).validated() : answer.validated();
        return query(principal, "select salud_u.registrar_mis_consentimientos(?, ?, ?, ?)::text",
            valid.termsVersion(), valid.termsAccepted(), valid.researchVersion(), valid.researchAccepted());
    }

    @Transactional(readOnly = true)
    public Object forPatient(SessionPrincipal principal, UUID patientId) {
        return query(principal, "select salud_u.obtener_consentimientos_paciente(?)::text", patientId);
    }

    @Transactional
    public Object saveForPatient(SessionPrincipal principal, UUID patientId, ConsentAnswer answer) {
        ConsentAnswer valid = answer == null ? new ConsentAnswer(null, null, null, null).validated() : answer.validated();
        return query(principal, "select salud_u.registrar_consentimientos_paciente(?, ?, ?, ?, ?)::text",
            patientId, valid.termsVersion(), valid.termsAccepted(), valid.researchVersion(), valid.researchAccepted());
    }

    /**
     * Respaldo del backend al crear una solicitud: registra la respuesta si llegó y, si la obligación está activa,
     * exige que no quede nada pendiente. patientId null es la ficha propia del estudiante.
     */
    @Transactional
    public void recordAndRequire(SessionPrincipal principal, UUID patientId, ConsentAnswer answer) {
        if (answer != null) {
            if (patientId == null) saveMine(principal, answer);
            else saveForPatient(principal, patientId, answer);
        }
        if (!required) return;
        apply(principal);
        Boolean pending;
        try {
            pending = jdbc.queryForObject("select salud_u.consentimiento_pendiente(?)", Boolean.class, patientId);
        } catch (DataAccessException exception) {
            throw translated(exception);
        }
        if (Boolean.TRUE.equals(pending)) throw new ConsentPendingException();
    }

    private Object query(SessionPrincipal principal, String sql, Object... args) {
        apply(principal);
        try {
            return json.readValue(jdbc.queryForObject(sql, String.class, args), Object.class);
        } catch (DataAccessException exception) {
            throw translated(exception);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Respuesta de consentimiento ilegible.", exception);
        }
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    private static RuntimeException translated(DataAccessException exception) {
        String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (detail.contains("VERSION_CONSENTIMIENTO_NO_VIGENTE")) return new AvailabilityException(409, "Los textos se actualizaron. Vuelve a leerlos y responde de nuevo.");
        if (detail.contains("CONSENTIMIENTO_INVALIDO")) return new AvailabilityException(400, "Debes aceptar los términos y responder Sí o No sobre investigación.");
        if (detail.contains("PACIENTE_PROPIO_NO_ENCONTRADO") || detail.contains("PACIENTE_NO_ENCONTRADO")) return new AvailabilityException(404, "Estudiante no encontrado.");
        if (detail.contains("Se requiere el rol")) return new AvailabilityException(403, "No tienes permiso para registrar esta respuesta.");
        return exception;
    }
}

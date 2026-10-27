package bo.edu.uagrm.saludu.scheduling.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** O-07: propone el bloqueo de una jornada; las reprogramaciones se deciden con {@link ScheduleSuggestionService#decide}. */
@Service
public class BlockProposalService {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final ScheduleSuggestionService suggestions;

    public BlockProposalService(JdbcTemplate jdbc, DatabaseActorContext actorContext, ScheduleSuggestionService suggestions) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.suggestions = suggestions;
    }

    @Transactional
    public BlockProposal propose(SessionPrincipal principal, UUID staffId, LocalDate date, LocalTime start, LocalTime end, String label) {
        apply(principal);
        try {
            UUID id = jdbc.queryForObject("select salud_u.proponer_bloqueo_jornada(?, ?, ?, ?, ?)", UUID.class, staffId, date, start, end, label);
            return read(id);
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
    }

    @Transactional(readOnly = true)
    public BlockProposal get(SessionPrincipal principal, UUID id) {
        apply(principal);
        try {
            return read(id);
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
    }

    /** Registra el bloqueo si ya no quedan citas en el horario (por ejemplo, tras cancelar las que se rechazó mover). */
    @Transactional
    public BlockProposal applyBlock(SessionPrincipal principal, UUID id) {
        apply(principal);
        try {
            jdbc.queryForObject("select salud_u.aplicar_propuesta_bloqueo(?)::text", String.class, id);
            return read(id);
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
    }

    private BlockProposal read(UUID id) {
        return jdbc.queryForObject("select * from salud_u.obtener_propuesta_bloqueo(?)", (rs, n) -> {
            LocalDate date = rs.getObject("fecha_bloqueo", LocalDate.class);
            return new BlockProposal(rs.getObject("id", UUID.class), rs.getObject("id_personal", UUID.class), rs.getString("nombre_personal"),
                date, rs.getObject("inicia_a", LocalTime.class), rs.getObject("termina_a", LocalTime.class), rs.getString("etiqueta"),
                rs.getString("estado"), rs.getObject("id_bloqueo", UUID.class), rs.getInt("citas_pendientes"),
                rs.getObject("creado_en", OffsetDateTime.class), rs.getObject("aplicada_en", OffsetDateTime.class),
                suggestions.query(date).stream().filter(s -> "RESCHEDULE".equals(s.type())
                    && id.toString().equals(s.suggestedValue().path("blockProposalId").asText())).toList());
        }, id);
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    private static RuntimeException translate(DataAccessException exception) {
        String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (detail.contains("Se requiere el rol ADMINISTRATIVO")) return new AvailabilityException(403, "Solo Administración puede proponer bloqueos con reprogramación.");
        if (detail.contains("PROPUESTA_BLOQUEO_INVALIDA")) return new AvailabilityException(400, "El bloqueo debe tener fecha vigente, nombre y horario válido.");
        if (detail.contains("PERSONAL_NO_ENCONTRADO")) return new AvailabilityException(404, "El médico no existe o no está activo.");
        if (detail.contains("PROPUESTA_BLOQUEO_NO_ENCONTRADA")) return new AvailabilityException(404, "La propuesta de bloqueo no existe.");
        if (detail.contains("PROPUESTA_BLOQUEO_EXISTENTE")) return new AvailabilityException(409, "Ya hay una propuesta de bloqueo pendiente para ese horario.");
        if (detail.contains("BLOQUEO_CON_CITA_INICIADA")) return new AvailabilityException(409, "El horario tiene una cita que ya empezó o un paciente presente; no se puede reprogramar.");
        if (detail.contains("PROPUESTA_CON_CITAS")) return new AvailabilityException(409, "Todavía hay citas en el horario; reprográmalas o cancélalas antes de bloquear.");
        return exception;
    }
}

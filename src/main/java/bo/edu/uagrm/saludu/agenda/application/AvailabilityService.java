package bo.edu.uagrm.saludu.agenda.application;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AvailabilityService {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;
    private final ObjectMapper objectMapper;

    public AvailabilityService(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter, ObjectMapper objectMapper) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
        this.objectMapper = objectMapper;
    }

    @Transactional(readOnly = true)
    public Map<String, Object> management(SessionPrincipal principal, LocalDate from, LocalDate to) {
        requireClinician(principal);
        apply(principal);
        Map<String, Object> result = new LinkedHashMap<>();
        jdbcTemplate.query("select * from salud_u.listar_mi_disponibilidad(?, ?)", resultSet -> {
            try {
                result.put(resultSet.getString("kind"), objectMapper.readTree(resultSet.getString("payload")));
            } catch (JsonProcessingException exception) {
                throw new IllegalStateException("La disponibilidad almacenada no contiene JSON válido.", exception);
            }
        }, from, to);
        result.putIfAbsent("schedules", List.of());
        result.putIfAbsent("recurringBlocks", List.of());
        result.putIfAbsent("dateBlocks", List.of());
        result.putIfAbsent("slots", List.of());
        result.put("appointments", List.of());
        return result;
    }

    @Transactional(readOnly = true)
    public List<PublishedSlot> published(SessionPrincipal principal, boolean initialOnly) {
        boolean ownOnly = principal.roles().contains("REVIEW_DOCTOR") || principal.roles().contains("SPECIALIST");
        apply(principal);
        return jdbcTemplate.query("select * from salud_u.listar_disponibilidad_publicada(?, ?)", (resultSet, rowNumber) -> new PublishedSlot(
            resultSet.getObject("id", UUID.class), resultSet.getObject("id_especialidad", UUID.class), resultSet.getObject("inicia_a", OffsetDateTime.class), resultSet.getObject("termina_a", OffsetDateTime.class), resultSet.getInt("capacidad"), resultSet.getInt("cantidad_reservada"), resultSet.getString("estado"), resultSet.getString("nombre_medico")
        ), initialOnly, ownOnly);
    }

    @Transactional
    public int replace(SessionPrincipal principal, JsonNode rules, JsonNode recurringBlocks) {
        requireClinician(principal);
        apply(principal);
        int generated = jdbcTemplate.queryForObject("select salud_u.reemplazar_mi_horario_disponibilidad(cast(? as jsonb), cast(? as jsonb))", Integer.class, json(rules), json(recurringBlocks));
        auditWriter.append("AVAILABILITY_SCHEDULE_REPLACED", "availability_schedule", null, AuditOutcome.SUCCESS, Map.of("generatedSlots", generated));
        return generated;
    }

    @Transactional
    public UUID createBlock(SessionPrincipal principal, LocalDate date, LocalTime startsAt, LocalTime endsAt, String label) {
        requireClinician(principal);
        apply(principal);
        UUID id = jdbcTemplate.queryForObject("select salud_u.crear_mi_bloqueo_disponibilidad(?, ?, ?, ?)", UUID.class, date, startsAt, endsAt, label);
        auditWriter.append("AVAILABILITY_BLOCK_CREATED", "availability_block", id, AuditOutcome.SUCCESS, Map.of("wholeDay", startsAt == null));
        return id;
    }

    @Transactional
    public UUID publish(SessionPrincipal principal, OffsetDateTime startsAt, OffsetDateTime endsAt, int capacity, UUID specialtyId) {
        requireClinician(principal);
        apply(principal);
        UUID id = jdbcTemplate.queryForObject("select salud_u.publicar_mi_cupo_disponibilidad(?, ?, ?, ?)", UUID.class, startsAt, endsAt, capacity, specialtyId);
        auditWriter.append("AVAILABILITY_SLOT_PUBLISHED", "availability_slot", id, AuditOutcome.SUCCESS, Map.of("capacity", capacity));
        return id;
    }

    @Transactional
    public void deleteBlock(SessionPrincipal principal, UUID blockId) {
        requireClinician(principal);
        apply(principal);
        jdbcTemplate.query("select salud_u.eliminar_mi_bloqueo_disponibilidad(?)", resultSet -> {}, blockId);
        auditWriter.append("AVAILABILITY_BLOCK_DELETED", "availability_block", blockId, AuditOutcome.SUCCESS, Map.of());
    }

    private void requireClinician(SessionPrincipal principal) {
        if (!(principal.roles().contains("REVIEW_DOCTOR") || principal.roles().contains("SPECIALIST"))) {
            throw new AvailabilityException(403, "La agenda de disponibilidad pertenece al médico.");
        }
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), java.util.Set.copyOf(principal.roles())));
    }

    private String json(JsonNode node) {
        try {
            return objectMapper.writeValueAsString(node == null ? objectMapper.createArrayNode() : node);
        } catch (JsonProcessingException exception) {
            throw new AvailabilityException(400, "La configuración de disponibilidad no es válida.");
        }
    }

    public record PublishedSlot(UUID id, UUID specialtyId, OffsetDateTime startsAt, OffsetDateTime endsAt, int capacity, int bookedCount, String status, String doctorName) {
    }
}

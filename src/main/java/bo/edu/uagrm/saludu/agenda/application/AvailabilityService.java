package bo.edu.uagrm.saludu.agenda.application;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
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
                String kind = switch (resultSet.getString("kind")) {
                    case "horarios" -> "schedules";
                    case "recurrenteBlocks" -> "recurringBlocks";
                    case "cupos" -> "slots";
                    default -> resultSet.getString("kind");
                };
                JsonNode payload = objectMapper.readTree(resultSet.getString("payload"));
                if (payload.isArray()) for (JsonNode item : payload) if (item instanceof ObjectNode value) {
                    Map<String, String> fields = Map.ofEntries(
                        Map.entry("id_especialidad", "specialty_id"), Map.entry("dia_semana", "weekday"),
                        Map.entry("inicia_a", "starts_at"), Map.entry("termina_a", "ends_at"),
                        Map.entry("duracion_cupo_minutos", "slot_duration_minutes"), Map.entry("etiqueta", "label"),
                        Map.entry("fecha_bloqueo", "block_date"), Map.entry("capacidad", "capacity"),
                        Map.entry("cantidad_reservada", "booked_count"), Map.entry("estado", "status"));
                    fields.forEach((source, target) -> { if (value.has(source)) value.set(target, value.remove(source)); });
                }
                result.put(kind, payload);
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
        int generated = jdbcTemplate.queryForObject("select salud_u.reemplazar_mi_horario_disponibilidad(cast(? as jsonb), cast(? as jsonb))", Integer.class, json(normalizeRules(rules)), json(normalizeRecurringBlocks(recurringBlocks)));
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
        UUID id;
        try {
            id = jdbcTemplate.queryForObject("select salud_u.publicar_mi_cupo_disponibilidad(?, ?, ?, ?)", UUID.class, startsAt, endsAt, capacity, specialtyId);
        } catch (DataAccessException exception) {
            throw slotRejection(exception);
        }
        auditWriter.append("AVAILABILITY_SLOT_PUBLISHED", "availability_slot", id, AuditOutcome.SUCCESS, Map.of("capacity", capacity));
        return id;
    }

    // La función SQL rechaza superposición, bloqueo, rango o especialidad con mensajes para el usuario; antes llegaban como 500 genérico.
    private static RuntimeException slotRejection(DataAccessException exception) {
        if (exception.getMostSpecificCause() instanceof java.sql.SQLException sql && sql.getSQLState() != null && sql.getMessage() != null) {
            String message = sql.getMessage().lines().findFirst().orElse("").replaceFirst("^ERROR: ", "") + ".";
            if (sql.getSQLState().equals("23505") || message.startsWith("El cupo coincide con un bloqueo")) return new AvailabilityException(409, message);
            if (sql.getSQLState().startsWith("22") || sql.getSQLState().startsWith("23")) return new AvailabilityException(400, message);
        }
        return exception;
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

    private ArrayNode normalizeRules(JsonNode rules) {
        return normalizeScheduleItems(rules, "slotDurationMinutes", "cupoDurationMinutes", "specialtyId", "especialidadId", null, null);
    }

    private ArrayNode normalizeRecurringBlocks(JsonNode blocks) {
        return normalizeScheduleItems(blocks, null, null, null, null, "label", "etiqueta");
    }

    private ArrayNode normalizeScheduleItems(JsonNode items, String sourceDuration, String targetDuration, String sourceSpecialty, String targetSpecialty, String sourceLabel, String targetLabel) {
        ArrayNode normalized = objectMapper.createArrayNode();
        if (items == null || !items.isArray()) return normalized;
        for (JsonNode item : items) {
            if (!item.isObject()) { normalized.add(item); continue; }
            ObjectNode value = ((ObjectNode) item).deepCopy();
            rename(value, "weekday", "dia_semana");
            rename(value, sourceDuration, targetDuration);
            rename(value, sourceSpecialty, targetSpecialty);
            rename(value, sourceLabel, targetLabel);
            normalized.add(value);
        }
        return normalized;
    }

    private static void rename(ObjectNode value, String source, String target) {
        if (source != null && target != null && value.has(source) && !value.has(target)) value.set(target, value.get(source));
    }

    public record PublishedSlot(UUID id, UUID specialtyId, OffsetDateTime startsAt, OffsetDateTime endsAt, int capacity, int bookedCount, String status, String doctorName) {
    }
}

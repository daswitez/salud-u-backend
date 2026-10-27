package bo.edu.uagrm.saludu.scheduling.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

/** O-04: genera las sugerencias de los próximos diez días hábiles con {@link SugeridorAgenda} y las lista. */
@Service
public class ScheduleSuggestionService {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final ObjectMapper json;
    private final SugeridorAgenda sugeridor = new SugeridorAgenda();

    public ScheduleSuggestionService(JdbcTemplate jdbc, DatabaseActorContext actorContext, ObjectMapper json) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.json = json;
    }

    /** Regenera las sugerencias pendientes de [desde, décimo día hábil]; devuelve cuántas cambiaron. */
    @Transactional(isolation = Isolation.REPEATABLE_READ)
    public int generate(LocalDate desde) {
        LocalDate hasta = SugeridorAgenda.ultimoDiaHabil(desde, SugeridorAgenda.DIAS_HABILES);
        List<SugeridorAgenda.Sugerencia> sugerencias = new ArrayList<>();
        jdbc.query("select * from salud_u.jornadas_para_sugerencias(?, ?)", rs -> {
            List<Map<String, Object>> cupos = read(rs.getString("cupos"));
            sugerencias.addAll(sugeridor.jornada(new SugeridorAgenda.Jornada(rs.getObject("fecha", LocalDate.class),
                rs.getObject("id_personal", UUID.class), rs.getObject("id_especialidad", UUID.class),
                rs.getObject("inicia_a", OffsetDateTime.class),
                cupos.stream().map(c -> new SugeridorAgenda.Cupo(UUID.fromString((String) c.get("id_cupo")),
                    OffsetDateTime.parse((String) c.get("inicia_a")), ((Number) c.get("capacidad")).intValue(),
                    ((Number) c.get("ocupados")).intValue())).toList(),
                rs.getBigDecimal("alfa").doubleValue(), rs.getBigDecimal("beta").doubleValue(), rs.getString("fuente"),
                rs.getBoolean("sobrecupo_decidido"))));
        }, desde, hasta);
        jdbc.query("select * from salud_u.demanda_para_alertas(?, ?)", rs -> {
            sugeridor.alerta(new SugeridorAgenda.DemandaEspecialidad(rs.getObject("id_especialidad", UUID.class),
                rs.getInt("solicitudes_pendientes"), rs.getInt("cupos_publicados"), rs.getInt("cupos_libres"),
                rs.getBigDecimal("demanda_estimada").doubleValue(), rs.getInt("dias_habiles"), rs.getInt("dias_sin_estimacion")),
                desde, hasta).ifPresent(sugerencias::add);
        }, desde, hasta);

        ArrayNode filas = json.createArrayNode();
        for (SugeridorAgenda.Sugerencia sugerencia : sugerencias) {
            ObjectNode fila = filas.addObject();
            fila.put("tipo", sugerencia.tipo());
            fila.put("fecha", sugerencia.fecha().toString());
            fila.put("id_personal", sugerencia.idPersonal() == null ? null : sugerencia.idPersonal().toString());
            fila.put("id_especialidad", sugerencia.idEspecialidad() == null ? null : sugerencia.idEspecialidad().toString());
            fila.set("valor_sugerido", json.valueToTree(sugerencia.valor()));
            fila.put("explicacion", sugerencia.explicacion());
            fila.put("vence_en", sugerencia.venceEn().toString());
        }
        return jdbc.queryForObject("select salud_u.guardar_sugerencias_agenda(cast(? as jsonb), ?, ?, ?)", Integer.class,
            filas.toString(), SugeridorAgenda.VERSION_MODELO, desde, hasta);
    }

    @Transactional(readOnly = true)
    public List<ScheduleSuggestion> list(SessionPrincipal principal, LocalDate date) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try {
            return query(date);
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
    }

    /**
     * O-06 y O-07: registra la decisión y aplica su efecto en una transacción: un sobrecupo sube la capacidad de los
     * cupos y una reprogramación mueve la cita. {@code slots} solo va con MODIFIED: [{id_cupo, capacidad}] para un
     * sobrecupo o [{id_cupo}] para una reprogramación, con claves internas.
     */
    @Transactional
    public ScheduleSuggestion decide(SessionPrincipal principal, UUID id, String decision, String reason, ArrayNode slots) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try {
            LocalDate date = jdbc.queryForObject("select salud_u.decidir_sugerencia_agenda(?, ?, ?, cast(? as jsonb))", LocalDate.class,
                id, decision, reason, slots == null ? null : slots.toString());
            return query(date).stream().filter(s -> s.id().equals(id)).findFirst().orElseThrow();
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
    }

    /** Marca VENCIDA lo que no se decidió antes de vence_en; la agenda no cambia. */
    @Transactional
    public int expire() {
        return jdbc.queryForObject("select salud_u.vencer_sugerencias_agenda()", Integer.class);
    }

    /** Sin actor: quien llama ya lo aplicó. */
    List<ScheduleSuggestion> query(LocalDate date) {
        return jdbc.query("select * from salud_u.listar_sugerencias_agenda(?)", (rs, n) -> {
            try {
                OffsetDateTime decidedAt = rs.getObject("decidida_en", OffsetDateTime.class);
                String applied = rs.getString("valor_aplicado");
                ScheduleSuggestion.Decision decision = decidedAt == null ? null : new ScheduleSuggestion.Decision(decidedAt,
                    rs.getObject("decidida_por", UUID.class), rs.getString("nombre_decidida_por"), rs.getString("motivo_decision"),
                    applied == null ? null : json.readTree(applied));
                return new ScheduleSuggestion(rs.getObject("id", UUID.class), rs.getString("tipo"), rs.getObject("fecha", LocalDate.class),
                    rs.getObject("id_especialidad", UUID.class), rs.getString("nombre_especialidad"), rs.getObject("id_personal", UUID.class),
                    rs.getString("nombre_personal"), json.readTree(rs.getString("valor_sugerido")), rs.getString("explicacion"),
                    rs.getString("version_modelo"), rs.getObject("vence_en", OffsetDateTime.class), rs.getString("estado"),
                    rs.getObject("creado_en", OffsetDateTime.class), rs.getObject("actualizado_en", OffsetDateTime.class), decision);
            } catch (JsonProcessingException exception) { throw new IllegalStateException("Sugerencia ilegible.", exception); }
        }, date);
    }

    private static RuntimeException translate(DataAccessException exception) {
        String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (detail.contains("Se requiere el rol ADMINISTRATIVO"))
            return new AvailabilityException(403, "Solo Administración puede revisar y decidir las sugerencias de agenda.");
        if (detail.contains("SUGERENCIA_NO_ENCONTRADA")) return new AvailabilityException(404, "La sugerencia no existe.");
        if (detail.contains("SUGERENCIA_YA_DECIDIDA")) return new AvailabilityException(409, "La sugerencia ya tiene una decisión.");
        if (detail.contains("SUGERENCIA_VENCIDA")) return new AvailabilityException(409, "La sugerencia venció sin decisión; la agenda no cambió.");
        if (detail.contains("SUGERENCIA_NO_DECIDIBLE")) return new AvailabilityException(409, "Este tipo de sugerencia todavía no se puede decidir.");
        if (detail.contains("SUGERENCIA_DESACTUALIZADA"))
            return new AvailabilityException(409, "La jornada cambió desde que se generó la sugerencia; se actualizará en la próxima generación.");
        if (detail.contains("SOBRECUPO_EXCEDE_LIMITE"))
            return new AvailabilityException(400, "El sobrecupo supera el 10 % de la capacidad de la jornada (RN-35).");
        if (detail.contains("MOTIVO_DECISION_REQUERIDO")) return new AvailabilityException(400, "Indica el motivo para modificar o rechazar la sugerencia.");
        if (detail.contains("REPROGRAMACION_SIN_CUPO"))
            return new AvailabilityException(400, "No hay un cupo sugerido; modifica la sugerencia eligiendo otro cupo o recházala.");
        if (detail.contains("CITA_NO_REPROGRAMABLE")) return new AvailabilityException(409, "La cita ya no está programada a futuro o ya tiene una atención.");
        if (detail.contains("CUPO_NO_DISPONIBLE")) return new AvailabilityException(409, "El cupo ya no está disponible.");
        if (detail.contains("CUPO_INCOMPATIBLE")) return new AvailabilityException(400, "El cupo no es de la misma especialidad que la cita.");
        if (detail.contains("PACIENTE_CON_CITA_ACTIVA")) return new AvailabilityException(409, "El paciente ya tiene otra cita en ese horario.");
        if (detail.contains("DECISION_SUGERENCIA_INVALIDA")) return new AvailabilityException(400, "La decisión no es válida para esta sugerencia.");
        return exception;
    }

    private List<Map<String, Object>> read(String value) {
        try { return json.readValue(value, new TypeReference<>() {}); }
        catch (JsonProcessingException exception) { throw new IllegalStateException("Cupos ilegibles.", exception); }
    }
}

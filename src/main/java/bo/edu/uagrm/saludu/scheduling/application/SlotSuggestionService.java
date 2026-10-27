package bo.edu.uagrm.saludu.scheduling.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** O-05: ordena con {@link SugeridorCupoSolicitud} los cupos que la asignación aceptaría. No escribe nada. */
@Service
public class SlotSuggestionService {
    private static final ZoneId BOLIVIA = ZoneId.of("America/La_Paz");
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;
    private final ObjectMapper json;
    private final SugeridorCupoSolicitud sugeridor = new SugeridorCupoSolicitud();

    public SlotSuggestionService(JdbcTemplate jdbc, DatabaseActorContext actorContext, ObjectMapper json) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
        this.json = json;
    }

    @Transactional(readOnly = true)
    public SuggestedSlots suggest(SessionPrincipal principal, UUID requestId) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        Map<String, Object> fila;
        try {
            fila = jdbc.queryForMap("select tipo_cita, prioridad, cupos::text as cupos from salud_u.cupos_para_solicitud(?)", requestId);
        } catch (DataAccessException exception) {
            throw translate(exception);
        }
        String tipo = (String) fila.get("tipo_cita"), prioridad = (String) fila.get("prioridad");
        List<SugeridorCupoSolicitud.Candidato> candidatos = new ArrayList<>();
        for (JsonNode c : read((String) fila.get("cupos")))
            candidatos.add(new SugeridorCupoSolicitud.Candidato(UUID.fromString(c.path("id_cupo").asText()),
                OffsetDateTime.parse(c.path("inicia_a").asText()), OffsetDateTime.parse(c.path("termina_a").asText()),
                UUID.fromString(c.path("id_personal").asText()), c.path("nombre_personal").asText(),
                c.path("id_especialidad").isNull() ? null : UUID.fromString(c.path("id_especialidad").asText()),
                c.path("nombre_especialidad").isNull() ? null : c.path("nombre_especialidad").asText(),
                c.path("lugares_libres").asInt(), c.path("capacidad_jornada").asInt(), c.path("ocupados_jornada").asInt(),
                c.path("asistencia").asDouble(), c.path("fuente").asText()));
        double w = SugeridorCupoSolicitud.pesoEspera(prioridad);
        List<SuggestedSlots.Slot> slots = sugeridor.ordenar(candidatos, prioridad, LocalDate.now(BOLIVIA)).stream()
            .map(s -> new SuggestedSlots.Slot(s.orden(), s.cupo().idCupo(), s.cupo().iniciaA(), s.cupo().terminaA(), s.cupo().idPersonal(),
                s.cupo().nombrePersonal(), s.cupo().idEspecialidad(), s.cupo().nombreEspecialidad(), s.cupo().lugaresLibres(), s.diasEspera(),
                s.ocupacionEsperada(), s.cupo().asistencia(), s.cupo().fuente(), s.puntaje(), s.explicacion()))
            .toList();
        return new SuggestedSlots(requestId, tipo, prioridad, SugeridorCupoSolicitud.VERSION_MODELO, w, Math.round((1 - w) * 100) / 100.0, slots);
    }

    private JsonNode read(String value) {
        try { return json.readTree(value); }
        catch (JsonProcessingException exception) { throw new IllegalStateException("Cupos ilegibles.", exception); }
    }

    private static AvailabilityException translate(DataAccessException exception) {
        String detail = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (detail.contains("Se requiere el rol ADMINISTRATIVO")) return new AvailabilityException(403, "Solo Administración puede consultar cupos sugeridos.");
        if (detail.contains("SOLICITUD_NO_ENCONTRADA")) return new AvailabilityException(404, "La solicitud no existe.");
        if (detail.contains("SOLICITUD_NO_PENDIENTE")) return new AvailabilityException(409, "La solicitud ya no está pendiente.");
        if (detail.contains("DERIVACION_NO_PROGRAMABLE")) return new AvailabilityException(409, "La derivación ya no está disponible para programar.");
        throw exception;
    }
}

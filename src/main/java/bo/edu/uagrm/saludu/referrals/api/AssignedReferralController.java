package bo.edu.uagrm.saludu.referrals.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/medical/assigned-referrals")
@PreAuthorize("hasRole('SPECIALIST')")
public class AssignedReferralController {
    private final JdbcTemplate jdbc; private final DatabaseActorContext actors; private final AuditWriter audit; private final ObjectMapper json;
    public AssignedReferralController(JdbcTemplate jdbc,DatabaseActorContext actors,AuditWriter audit,ObjectMapper json){this.jdbc=jdbc;this.actors=actors;this.audit=audit;this.json=json;}
    @GetMapping @Transactional
    public LegacyAvailabilityResponse<JsonNode> list(@AuthenticationPrincipal SessionPrincipal p){
        var data=read(p,null);audit.append("DERIVACIONES_ASIGNADAS_CONSULTADAS","principal",p.id(),AuditOutcome.SUCCESS,Map.of());return LegacyAvailabilityResponse.success(data);
    }
    @GetMapping("/{id}") @Transactional
    public LegacyAvailabilityResponse<JsonNode> get(@PathVariable UUID id,@AuthenticationPrincipal SessionPrincipal p){
        var data=read(p,id);if(data.isEmpty())throw new AvailabilityException(404,"No se encontró una derivación asignada accesible.");
        audit.append("DERIVACION_ASIGNADA_CONSULTADA","derivacion",id,AuditOutcome.SUCCESS,Map.of());return LegacyAvailabilityResponse.success(data.get(0));
    }
    private JsonNode read(SessionPrincipal p,UUID id){
        actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));
        try{return json.readTree(jdbc.queryForObject("select salud_u.consultar_derivaciones_asignadas(?)::text",String.class,id));}
        catch(DataAccessException ex){
            String detail=ex.getMostSpecificCause().getMessage();
            if(detail!=null&&detail.contains("No existe una ficha de personal activa"))throw new AvailabilityException(404,"No se encontró una derivación asignada accesible.");
            throw new AvailabilityException(500,"No se pudieron consultar las derivaciones asignadas. Reintenta la consulta.");
        }
        catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new AvailabilityException(500,"No se pudo leer la derivación asignada.");}
    }
}

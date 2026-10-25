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
@RequestMapping("/api/medical/referrals")
@PreAuthorize("hasRole('REVIEW_DOCTOR')")
public class EmittedReferralController {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actors;
    private final AuditWriter audit;
    private final ObjectMapper json;
    public EmittedReferralController(JdbcTemplate jdbc,DatabaseActorContext actors,AuditWriter audit,ObjectMapper json){
        this.jdbc=jdbc;this.actors=actors;this.audit=audit;this.json=json;
    }
    @GetMapping @Transactional
    public LegacyAvailabilityResponse<JsonNode> list(@AuthenticationPrincipal SessionPrincipal principal){
        apply(principal);
        JsonNode result=read("select salud_u.listar_derivaciones_emitidas_propias()::text");
        audit.append("DERIVACIONES_EMITIDAS_CONSULTADAS","principal",principal.id(),AuditOutcome.SUCCESS,Map.of());
        return LegacyAvailabilityResponse.success(result);
    }
    @GetMapping("/{id}") @Transactional
    public LegacyAvailabilityResponse<JsonNode> get(@PathVariable UUID id,@AuthenticationPrincipal SessionPrincipal principal){
        apply(principal);
        JsonNode result=read("select salud_u.obtener_derivacion_emitida_propia(?)::text",id);
        audit.append("DERIVACION_CONSULTADA","derivacion",id,AuditOutcome.SUCCESS,Map.of());
        return LegacyAvailabilityResponse.success(result);
    }
    private void apply(SessionPrincipal principal){actors.apply(new DatabaseActor(principal.id(),Set.copyOf(principal.roles())));}
    private JsonNode read(String sql,Object... args){
        try{return json.readTree(jdbc.queryForObject(sql,String.class,args));}
        catch(DataAccessException exception){
            String detail=exception.getMostSpecificCause().getMessage();
            if(detail!=null&&(detail.contains("DERIVACION_AJENA_O_INEXISTENTE")||detail.contains("No existe una ficha de personal activa")))throw new AvailabilityException(404,"No se encontró una derivación emitida accesible.");
            throw new AvailabilityException(500,"No se pudieron consultar las derivaciones emitidas.");
        }
        catch(com.fasterxml.jackson.core.JsonProcessingException exception){throw new AvailabilityException(500,"No se pudo leer la derivación emitida.");}
    }
}

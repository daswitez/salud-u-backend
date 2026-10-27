package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController @RequestMapping("/api/medical/encounters")
@PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')")
public class EncounterAmendmentController {
    public record Created(UUID id,int amendmentNo,OffsetDateTime createdAt,UUID createdBy) {}
    private final JdbcTemplate jdbc;private final DatabaseActorContext actors;private final AuditWriter audit;private final ObjectMapper json;
    public EncounterAmendmentController(JdbcTemplate jdbc,DatabaseActorContext actors,AuditWriter audit,ObjectMapper json){this.jdbc=jdbc;this.actors=actors;this.audit=audit;this.json=json;}
    @GetMapping("/{id}/amendments") @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<JsonNode>> list(@PathVariable UUID id,@AuthenticationPrincipal SessionPrincipal p){
        apply(p);
        try{
            var data=json.readTree(jdbc.queryForObject("select salud_u.obtener_adendas_autorizadas(?)::text",String.class,id));
            audit.append("ADENDAS_ENCUENTRO_CONSULTADAS","encuentro_clinico",id,AuditOutcome.SUCCESS,Map.of());
            return ResponseEntity.ok().header("Cache-Control","no-store, private").body(LegacyAvailabilityResponse.success(data));
        }catch(DataAccessException ex){throw translate(ex);}catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new AvailabilityException(500,"No se pudieron leer las adendas.");}
    }
    @PostMapping("/{id}/amendments") @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<Created>> add(@PathVariable UUID id,@RequestBody Map<String,Object> body,@AuthenticationPrincipal SessionPrincipal p){
        String reason=text(body.get("reason"),1000),content=text(body.get("content"),8000);UUID requestId=null;
        if(body.get("clientRequestId")!=null)try{requestId=UUID.fromString((String)body.get("clientRequestId"));}catch(IllegalArgumentException|ClassCastException ex){throw new AvailabilityException(400,"El identificador de reintento no es válido.");}
        apply(p);
        try{
            var data=jdbc.queryForObject("select * from salud_u.agregar_adenda_encuentro(?,?,?,?)",(r,n)->new Created(r.getObject("id",UUID.class),r.getInt("numero_adenda"),r.getObject("creada_en",OffsetDateTime.class),r.getObject("creada_por",UUID.class)),id,reason,content,requestId);
            return ResponseEntity.ok().header("Cache-Control","no-store, private").body(LegacyAvailabilityResponse.success(data));
        }catch(DataAccessException ex){throw translate(ex);}
    }
    private void apply(SessionPrincipal p){actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));}
    private static String text(Object value,int max){if(!(value instanceof String text)||text.trim().isEmpty()||text.trim().length()>max)throw new AvailabilityException(400,"El motivo y contenido de la adenda son obligatorios y deben respetar sus límites.");return text.trim();}
    private static AvailabilityException translate(DataAccessException ex){
        String detail=ex.getMostSpecificCause().getMessage();
        if(detail!=null&&detail.contains("SOLICITUD_ADENDA_REUTILIZADA"))return new AvailabilityException(409,"Ese envío ya quedó guardado con otro contenido. Comprueba las adendas antes de crear una nueva.");
        if(detail!=null&&detail.contains("ADENDA_INVALIDA"))return new AvailabilityException(400,"El motivo o contenido de la adenda no es válido.");
        if(detail!=null&&(detail.contains("ADENDA_NO_AUTORIZADA")||detail.contains("PACIENTE_SIN_ACCESO_CLINICO")||detail.contains("No existe una ficha de personal activa")))return new AvailabilityException(403,"No se puede acceder o agregar una adenda a esta atención.");
        return new AvailabilityException(500,"No pudimos confirmar la adenda. Consulta su estado antes de reintentar.");
    }
}

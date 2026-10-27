package bo.edu.uagrm.saludu.governance.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.*;
import java.time.*;
import java.util.*;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController @RequestMapping("/api/audit-events")
public class AuditEventController {
 private final JdbcTemplate jdbc;private final DatabaseActorContext actorContext;private final AuditWriter auditWriter;
 public AuditEventController(JdbcTemplate jdbc,DatabaseActorContext actorContext,AuditWriter auditWriter){this.jdbc=jdbc;this.actorContext=actorContext;this.auditWriter=auditWriter;}
 @GetMapping @PreAuthorize("hasRole('AUDITOR')") @Transactional
 public ResponseEntity<Map<String,Object>> list(@RequestParam(required=false) LocalDate from,@RequestParam(required=false) LocalDate to,@RequestParam(required=false) UUID actorId,@RequestParam(required=false) String actor,@RequestParam(required=false) String action,@RequestParam(required=false) String resource,@RequestParam(required=false) String outcome,@RequestParam(defaultValue="100") int limit,@RequestParam(defaultValue="false") boolean paginated,@RequestParam(required=false) String before,@AuthenticationPrincipal SessionPrincipal principal){
  if(from!=null&&to!=null&&from.isAfter(to)||limit<1||limit>500)throw invalid();
  action=filter(action);resource=filter(resource);actor=filter(actor);outcome=filter(outcome);if(outcome!=null)outcome=outcome.toUpperCase(Locale.ROOT);if(outcome!=null&&!Set.of("SUCCESS","DENIED","FAILURE").contains(outcome))throw invalid();
  OffsetDateTime cursorTime=null;UUID cursorId=null;if(before!=null){try{if(!paginated||before.length()>120)throw invalid();String[] parts=before.split("\\|",-1);if(parts.length!=2)throw invalid();cursorTime=OffsetDateTime.parse(parts[0]);cursorId=UUID.fromString(parts[1]);}catch(IllegalArgumentException|java.time.DateTimeException ex){throw invalid();}}
  actorContext.apply(new DatabaseActor(principal.id(),Set.copyOf(principal.roles())));
  try{
   List<Map<String,Object>> events=jdbc.query("select * from salud_u.listar_eventos_auditoria_paginados(?,?,?,?,?,?,?,?,?,?)",(rs,n)->{
    Map<String,Object> event=new LinkedHashMap<>();event.put("id",rs.getObject("id",UUID.class));event.put("occurredAt",rs.getObject("ocurrido_en",OffsetDateTime.class));Map<String,Object> person=new LinkedHashMap<>();person.put("id",rs.getObject("id_actor",UUID.class));person.put("name",rs.getString("nombre_actor"));var roles=rs.getArray("roles_actor");person.put("roles",roles==null?new String[0]:roles.getArray());event.put("actor",person);event.put("action",rs.getString("accion"));event.put("resource",rs.getString("tipo_recurso"));event.put("resourceId",rs.getObject("id_recurso",UUID.class));event.put("outcome",rs.getString("resultado"));event.put("context","Evento operacional "+rs.getString("accion")+" sobre "+rs.getString("tipo_recurso")+".");return event;
   },from,to,actorId,action,resource,outcome,limit+(paginated?1:0),cursorTime,cursorId,actor);
   boolean more=paginated&&events.size()>limit;if(more)events=new ArrayList<>(events.subList(0,limit));Map<String,Object> response=new LinkedHashMap<>();response.put("ok",true);response.put("data",events);response.put("error",null);
   if(paginated){Map<String,Object> pagination=new LinkedHashMap<>();pagination.put("hasMore",more);pagination.put("nextCursor",more?events.getLast().get("occurredAt")+"|"+events.getLast().get("id"):null);response.put("pagination",pagination);}
   auditWriter.append("AUDIT_EVENTS_READ","audit_event",null,AuditOutcome.SUCCESS,Map.of("limit",limit,"count",events.size()));return ResponseEntity.ok().header("Cache-Control","no-store, private").body(response);
  }catch(DataAccessException ex){String message=ex.getMostSpecificCause().getMessage();if(message!=null&&message.contains("AUDITOR_REQUERIDO"))throw new AvailabilityException(403,"No tienes permiso para consultar la auditoría.");throw new AvailabilityException(500,"No se pudo consultar la auditoría. Puedes reintentar.");}
 }
 private static String filter(String text){if(text==null||text.isBlank())return null;if(text.trim().length()>200)throw invalid();return text.trim();}
 private static AvailabilityException invalid(){return new AvailabilityException(400,"Los filtros de auditoría no son válidos.");}
}

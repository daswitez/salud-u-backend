package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
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

@RestController @RequestMapping("/api/medical/patients")
public class MedicalHistorySearchController {
    public record Result(UUID id,OffsetDateTime occurredAt,String encounterType,String status,String chiefComplaint,String assessment,String specialty) {}
    private final JdbcTemplate jdbc; private final DatabaseActorContext actors; private final AuditWriter audit;
    public MedicalHistorySearchController(JdbcTemplate jdbc,DatabaseActorContext actors,AuditWriter audit){this.jdbc=jdbc;this.actors=actors;this.audit=audit;}
    @GetMapping("/{id}/search") @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')") @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<List<Result>>> search(@PathVariable UUID id,@RequestParam(required=false) LocalDate from,@RequestParam(required=false) LocalDate to,@RequestParam(required=false) String q,@AuthenticationPrincipal SessionPrincipal p){
        if(q!=null&&q.trim().length()>200)throw new AvailabilityException(400,"El texto de búsqueda es demasiado largo.");
        if(from!=null&&to!=null&&from.isAfter(to))throw new AvailabilityException(400,"El rango de fechas no es válido.");
        actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));
        try{
            var data=jdbc.query("select * from salud_u.buscar_historia_autorizada(?,?,?,?)",(r,n)->new Result(r.getObject("id",UUID.class),r.getObject("ocurrido_en",OffsetDateTime.class),r.getString("tipo_encuentro"),r.getString("estado"),r.getString("motivo"),r.getString("evaluacion"),r.getString("especialidad")),id,from,to,q);
            audit.append("HISTORIA_LONGITUDINAL_BUSCADA","paciente",id,AuditOutcome.SUCCESS,Map.of("cantidadResultados",data.size(),"conTexto",q!=null&&!q.isBlank()));
            return ResponseEntity.ok().header("Cache-Control","no-store, private").body(LegacyAvailabilityResponse.success(data));
        }catch(DataAccessException ex){
            String detail=ex.getMostSpecificCause().getMessage();
            if(detail!=null&&(detail.contains("PACIENTE_SIN_ACCESO_CLINICO")||detail.contains("No existe una ficha de personal activa")))throw new AvailabilityException(404,"No tienes acceso clínico a este paciente.");
            throw new AvailabilityException(500,"No se pudo buscar en la historia clínica. Reintenta la consulta.");
        }
    }
}

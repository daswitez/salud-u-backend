package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.ObjectMapper;
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
public class MedicalPatientHistoryController {
    private final JdbcTemplate jdbc; private final DatabaseActorContext actors; private final ObjectMapper json; private final AuditWriter audit;
    public MedicalPatientHistoryController(JdbcTemplate jdbc,DatabaseActorContext actors,ObjectMapper json,AuditWriter audit){this.jdbc=jdbc;this.actors=actors;this.json=json;this.audit=audit;}
    @GetMapping("/{id}") @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')") @Transactional
    public ResponseEntity<LegacyAvailabilityResponse<Object>> get(@PathVariable UUID id,@AuthenticationPrincipal SessionPrincipal p){
        actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));
        try{
            Object data=json.readValue(jdbc.queryForObject("select salud_u.obtener_historia_longitudinal_area(?)::text",String.class,id),Object.class);
            audit.append("HISTORIA_LONGITUDINAL_CONSULTADA","paciente",id,AuditOutcome.SUCCESS,Map.of());
            return ResponseEntity.ok().header("Cache-Control","no-store, private").body(LegacyAvailabilityResponse.success(data));
        }catch(DataAccessException ex){
            String detail=ex.getMostSpecificCause().getMessage();
            if(detail!=null&&(detail.contains("PACIENTE_SIN_ACCESO_CLINICO")||detail.contains("No existe una ficha de personal activa")))throw new AvailabilityException(404,"No tienes acceso clínico a este paciente.");
            throw new AvailabilityException(500,"No se pudo consultar la historia clínica. Reintenta la consulta.");
        }catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new AvailabilityException(500,"No se pudo consultar la historia clínica.");}
    }
}

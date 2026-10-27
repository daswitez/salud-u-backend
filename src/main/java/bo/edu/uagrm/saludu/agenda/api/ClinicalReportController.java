package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.*;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.OffsetDateTime;
import java.util.*;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController @RequestMapping("/api/reports/clinical")
public class ClinicalReportController {
    private final JdbcTemplate jdbc;private final DatabaseActorContext actors;private final ObjectMapper json;private final AuditWriter audit;
    public ClinicalReportController(JdbcTemplate jdbc,DatabaseActorContext actors,ObjectMapper json,AuditWriter audit){this.jdbc=jdbc;this.actors=actors;this.json=json;this.audit=audit;}
    @GetMapping @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER','REVIEW_DOCTOR','SPECIALIST')") @Transactional
    public ResponseEntity<Map<String,Object>> get(@RequestParam Map<String,String> query,@AuthenticationPrincipal SessionPrincipal principal){
        var request=ClinicalReportQuery.parse(query,json);actors.apply(new DatabaseActor(principal.id(),Set.copyOf(principal.roles())));
        try{
            var rows=ClinicalReportRows.load(jdbc,json,request.filters(),0);
            Map<String,Object> payload=new LinkedHashMap<>();payload.put("ok",true);payload.put("data",rows);payload.put("filters",request.filters());if(request.presentation())payload.put("presentation",request.presentation(rows));
            audit.append("REPORTE_CLINICO_CONSULTADO","reporte_clinico",null,AuditOutcome.SUCCESS,Map.of("cantidadFilas",rows.size(),"columnas",request.columns(),"agrupaciones",request.groupBy()));
            return ResponseEntity.ok().header("Cache-Control","no-store, private").body(payload);
        }catch(DataAccessException ex){String detail=ex.getMostSpecificCause().getMessage();if(detail!=null&&(detail.contains("REPORTE_NO_AUTORIZADO")||detail.contains("No existe una ficha de personal activa")))throw new AvailabilityException(403,"No tienes acceso al reporte clínico.");throw new AvailabilityException(500,"No se pudo consultar el reporte clínico. Puedes reintentar.");}
        catch(com.fasterxml.jackson.core.JsonProcessingException|IllegalStateException ex){throw new AvailabilityException(500,"No se pudo consultar el reporte clínico. Puedes reintentar.");}
    }
}

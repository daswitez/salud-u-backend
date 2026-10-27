package bo.edu.uagrm.saludu.agenda.application;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
@Service
public class ClinicalReportExportHistory {
    private final JdbcTemplate jdbc;private final ObjectMapper json;private final DatabaseActorContext actors;
    public ClinicalReportExportHistory(JdbcTemplate jdbc,ObjectMapper json,DatabaseActorContext actors){this.jdbc=jdbc;this.json=json;this.actors=actors;}
    public UUID record(ClinicalReportExportRequest r,String state,int count,String digest){
        try{return jdbc.queryForObject("select salud_u.registrar_exportacion_reporte(?,cast(? as jsonb),cast(? as jsonb),cast(? as jsonb),?,?,?,?)",UUID.class,r.purpose(),json.writeValueAsString(r.query().filters()),json.writeValueAsString(r.query().columns()),json.writeValueAsString(r.query().groupBy()),r.format(),state,count,digest);}catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new IllegalStateException(ex);}
    }
    @Transactional(propagation=Propagation.REQUIRES_NEW)
    public void failed(ClinicalReportExportRequest r,int count,SessionPrincipal principal){actors.apply(new DatabaseActor(principal.id(),Set.copyOf(principal.roles())));record(r,"FAILED",count,null);}
}

package bo.edu.uagrm.saludu.agenda.application;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import java.security.MessageDigest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
@Service
public class ClinicalReportExportService {
    public record File(UUID id,String format,int rowCount,String sha256,byte[] bytes){}
    private final JdbcTemplate jdbc;private final ObjectMapper json;private final DatabaseActorContext actors;private final ClinicalReportFiles files;private final ClinicalReportExportHistory history;
    public ClinicalReportExportService(JdbcTemplate jdbc,ObjectMapper json,DatabaseActorContext actors,ClinicalReportFiles files,ClinicalReportExportHistory history){this.jdbc=jdbc;this.json=json;this.actors=actors;this.files=files;this.history=history;}
    @Transactional
    public File export(ClinicalReportExportRequest request,SessionPrincipal principal) throws java.io.IOException {
        actors.apply(new DatabaseActor(principal.id(),Set.copyOf(principal.roles())));
        var rows=ClinicalReportRows.load(jdbc,json,request.query().filters(),10001);
        if(rows.size()>10000)throw new AvailabilityException(400,"El reporte supera 10.000 atenciones. Reduce el período o agrega filtros.");
        byte[] bytes;
        try{bytes=files.render(request,rows);}catch(java.io.IOException|IllegalArgumentException ex){throw new ClinicalReportGenerationFailure(rows.size());}
        String hash;try{hash=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));}catch(java.security.NoSuchAlgorithmException ex){throw new IllegalStateException(ex);}
        UUID id=history.record(request,"COMPLETED",rows.size(),hash);
        return new File(id,request.format(),rows.size(),hash,bytes);
    }
}

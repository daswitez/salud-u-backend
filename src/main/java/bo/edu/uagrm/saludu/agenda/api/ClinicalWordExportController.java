package bo.edu.uagrm.saludu.agenda.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.agenda.application.ClinicalWordDocument;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import org.springframework.dao.DataAccessException;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController @RequestMapping("/api/medical/encounters")
public class ClinicalWordExportController {
    private final JdbcTemplate jdbc;private final DatabaseActorContext actors;private final ObjectMapper json;private final ClinicalWordDocument word;private final AuditWriter audit;
    public ClinicalWordExportController(JdbcTemplate jdbc,DatabaseActorContext actors,ObjectMapper json,ClinicalWordDocument word,AuditWriter audit){this.jdbc=jdbc;this.actors=actors;this.json=json;this.word=word;this.audit=audit;}
    @GetMapping("/{id}/export.docx") @PreAuthorize("hasAnyRole('REVIEW_DOCTOR','SPECIALIST')") @Transactional
    public ResponseEntity<byte[]> export(@PathVariable UUID id,@RequestParam(required=false) String purpose,@AuthenticationPrincipal SessionPrincipal p){
        String intended=purpose==null?"Consulta clínica autorizada":purpose.trim();
        if(intended.isBlank()||intended.length()>500)throw new AvailabilityException(400,"Indica una finalidad de entre 1 y 500 caracteres.");
        actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));
        try{
            var root=json.readTree(jdbc.queryForObject("select salud_u.obtener_ficha_exportable(?)::text",String.class,id));
            byte[] file=word.render(root,intended);
            var version=root.path("encounter").path(root.path("encounter").path("encounter_type").asText().equals("INITIAL")?"reviewHistoryVersion":"specialtyHistoryVersion");
            audit.append("FICHA_WORD_EXPORTADA","encuentro_clinico",id,AuditOutcome.SUCCESS,Map.of("finalidad",intended,"formato","DOCX","versionFicha",version.isIntegralNumber()?version.asInt():"NO_REGISTRADA","cantidadAdendas",root.path("amendments").size()));
            return ResponseEntity.ok().header(HttpHeaders.CONTENT_DISPOSITION,"attachment; filename=ficha-clinica-"+id+".docx").header(HttpHeaders.CACHE_CONTROL,"no-store, private").header("X-Content-Type-Options","nosniff").contentType(MediaType.parseMediaType("application/vnd.openxmlformats-officedocument.wordprocessingml.document")).contentLength(file.length).body(file);
        }catch(DataAccessException ex){
            String detail=ex.getMostSpecificCause().getMessage();
            if(detail!=null&&(detail.contains("FICHA_NO_AUTORIZADA")||detail.contains("PACIENTE_SIN_ACCESO_CLINICO")||detail.contains("ADENDA_NO_AUTORIZADA")||detail.contains("No existe una ficha de personal activa")))throw new AvailabilityException(404,"No tienes acceso clínico a esta ficha cerrada.");
            throw new AvailabilityException(500,"No se pudo generar el Word. Puedes reintentar la descarga.");
        }catch(java.io.IOException|IllegalArgumentException ex){throw new AvailabilityException(500,"No se pudo generar el Word. Puedes reintentar la descarga.");}
    }
}

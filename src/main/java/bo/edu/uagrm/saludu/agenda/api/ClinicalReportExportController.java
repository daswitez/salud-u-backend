package bo.edu.uagrm.saludu.agenda.api;
import bo.edu.uagrm.saludu.agenda.application.*;
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
@RestController @RequestMapping("/api/reports/clinical")
public class ClinicalReportExportController {
 private final JdbcTemplate j;private final DatabaseActorContext c;private final AuditWriter audit;private final ObjectMapper m;private final ClinicalReportExportService exports;private final ClinicalReportExportHistory history;
 public ClinicalReportExportController(JdbcTemplate j,DatabaseActorContext c,AuditWriter audit,ObjectMapper m,ClinicalReportExportService exports,ClinicalReportExportHistory history){this.j=j;this.c=c;this.audit=audit;this.m=m;this.exports=exports;this.history=history;}
@PostMapping @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER','REVIEW_DOCTOR','SPECIALIST')") @Transactional public ResponseEntity<?> log(@RequestBody Map<String,Object>b,@AuthenticationPrincipal SessionPrincipal p)throws Exception{
String format=b.get("format") instanceof String f?f:"";String purpose=b.get("purpose") instanceof String value&&!value.isBlank()?value.trim():"Gestión clínica";Object count=b.get("rowCount");if(!Set.of("CSV","XLSX","PDF").contains(format)||!(count instanceof Number number)||number.doubleValue()!=number.intValue()||number.intValue()<0||number.intValue()>10000||purpose.length()>300)throw new AvailabilityException(400,"Exportación inválida.");
c.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));UUID id=audit.append("EXPORTACION_REPORTE_CLINICO_REGISTRADA","reporte_clinico",null,AuditOutcome.SUCCESS,Map.of("format",format,"purpose",purpose,"rowCount",((Number)count).intValue()));return ResponseEntity.status(201).header("Cache-Control","no-store, private").body(LegacyAvailabilityResponse.success(Map.of("id",id)));}

 @PostMapping("/export") @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER','REVIEW_DOCTOR','SPECIALIST')")
 public ResponseEntity<byte[]> export(@RequestBody Map<String,Object> body,@AuthenticationPrincipal SessionPrincipal principal){
  var request=ClinicalReportExportRequest.parse(body,m);
  try{
   var file=exports.export(request,principal);String extension=file.format().toLowerCase(Locale.ROOT);
   String type=switch(file.format()){case "CSV"->"text/csv;charset=utf-8";case "XLSX"->"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";default->"application/pdf";};
   return ResponseEntity.ok().contentType(MediaType.parseMediaType(type)).contentLength(file.bytes().length)
    .header(HttpHeaders.CONTENT_DISPOSITION,"attachment; filename=reporte-clinico-"+file.id()+"."+extension)
    .header(HttpHeaders.CACHE_CONTROL,"no-store, private").header("X-Content-Type-Options","nosniff")
    .header("X-Export-Id",file.id().toString()).header("X-Export-Row-Count",Integer.toString(file.rowCount())).header("X-Content-SHA256",file.sha256()).body(file.bytes());
  }catch(ClinicalReportGenerationFailure ex){
   // The service transaction has rolled back and released its connection before recording failure.
   try{history.failed(request,ex.rowCount(),principal);}catch(DataAccessException failure){throw translated(failure);}
   throw new AvailabilityException(500,"No se pudo generar el archivo completo. Puedes reintentar o elegir otro formato.");
  }catch(DataAccessException ex){throw translated(ex);}catch(java.io.IOException|IllegalStateException ex){throw new AvailabilityException(500,"No se pudo generar el archivo completo. Puedes reintentar.");}
 }
 @GetMapping("/exports/{id}") @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER','REVIEW_DOCTOR','SPECIALIST')") @Transactional
 public ResponseEntity<LegacyAvailabilityResponse<com.fasterxml.jackson.databind.JsonNode>> status(@PathVariable UUID id,@AuthenticationPrincipal SessionPrincipal principal){
  c.apply(new DatabaseActor(principal.id(),Set.copyOf(principal.roles())));
  try{var data=m.readTree(j.queryForObject("select salud_u.obtener_exportacion_reporte(?)::text",String.class,id));audit.append("EXPORTACION_REPORTE_CONSULTADA","exportacion_reporte_clinico",id,AuditOutcome.SUCCESS,Map.of());return ResponseEntity.ok().header(HttpHeaders.CACHE_CONTROL,"no-store, private").body(LegacyAvailabilityResponse.success(data));}
  catch(DataAccessException ex){String detail=ex.getMostSpecificCause().getMessage();if(detail!=null&&detail.contains("EXPORTACION_NO_AUTORIZADA"))throw new AvailabilityException(404,"No tienes acceso a esta exportación.");throw translated(ex);}catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new AvailabilityException(500,"No se pudo consultar la exportación.");}
 }
 private static AvailabilityException translated(DataAccessException ex){String detail=ex.getMostSpecificCause().getMessage();if(detail!=null&&(detail.contains("REPORTE_NO_AUTORIZADO")||detail.contains("EXPORTACION_NO_AUTORIZADA")||detail.contains("No existe una ficha de personal activa")))return new AvailabilityException(403,"No tienes permiso para exportar este reporte.");return new AvailabilityException(500,"No se pudo completar la exportación. Puedes reintentar.");}
}

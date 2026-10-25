package bo.edu.uagrm.saludu.referrals.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController
public class ReferralController {
  private final JdbcTemplate jdbc; private final DatabaseActorContext actors; private final AuditWriter audit;
  public ReferralController(JdbcTemplate jdbc,DatabaseActorContext actors,AuditWriter audit){this.jdbc=jdbc;this.actors=actors;this.audit=audit;}
  private void apply(SessionPrincipal p){actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));}
  @GetMapping("/api/administrative/referrals") @PreAuthorize("hasRole('ADMINISTRATIVE')") @Transactional
  public LegacyAvailabilityResponse<List<Map<String,Object>>> inbox(@AuthenticationPrincipal SessionPrincipal p){
    apply(p);
    var result=jdbc.query("select * from salud_u.listar_bandeja_derivaciones_administracion()",(r,n)->{
      Map<String,Object> item=new java.util.LinkedHashMap<>();
      item.put("id",r.getObject("id",UUID.class));item.put("patient_id",r.getObject("patient_id",UUID.class));
      item.put("patient_name",r.getString("patient_name"));item.put("patient_carnet",r.getString("patient_carnet"));
      item.put("specialty_id",r.getObject("specialty_id",UUID.class));item.put("specialty_name",r.getString("specialty_name"));
      item.put("priority",r.getString("priority"));item.put("reason",r.getString("reason"));item.put("comment_for_specialist",r.getString("comment_for_specialist"));item.put("status",r.getString("status"));
      item.put("requested_at",r.getObject("requested_at"));item.put("requested_by_name",r.getString("requested_by_name"));
      item.put("assigned_staff_name",r.getString("assigned_staff_name"));item.put("appointment_id",r.getObject("appointment_id",UUID.class));item.put("scheduled_for",r.getObject("scheduled_for"));return item;
    });
    audit.append("BANDEJA_DERIVACIONES_CONSULTADA","principal",p.id(),AuditOutcome.SUCCESS,Map.of());
    return LegacyAvailabilityResponse.success(result);
  }
  @GetMapping("/api/patients/{patientId}/referrals") @PreAuthorize("hasRole('ADMINISTRATIVE')") @Transactional
  public LegacyAvailabilityResponse<List<Map<String,Object>>> patient(@PathVariable UUID patientId,@AuthenticationPrincipal SessionPrincipal p){
    apply(p);
    var result=jdbc.query("select * from salud_u.listar_derivaciones_paciente_para_cita(?)",(r,n)->Map.<String,Object>of("id",r.getObject("id",UUID.class),"specialty_id",r.getObject("specialty_id",UUID.class),"specialty_name",r.getString("specialty_name"),"status",r.getString("status")),patientId);
    audit.append("DERIVACIONES_PACIENTE_CONSULTADAS","paciente",patientId,AuditOutcome.SUCCESS,Map.of());
    return LegacyAvailabilityResponse.success(result);
  }
  @PatchMapping("/api/medical/referrals/{id}") @PreAuthorize("hasRole('SPECIALIST')") @Transactional
  public LegacyAvailabilityResponse<Map<String,Object>> resolve(@PathVariable UUID id,@RequestBody Map<String,Object> body,@AuthenticationPrincipal SessionPrincipal p){Object action=body.get("action");if(!(action instanceof String value)||!(value.equals("RESOLVE")||value.equals("RETURN")))throw new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(400,"Acción de derivación inválida.");Object reason=body.get("reason"),followUp=body.get("followUpText");if(value.equals("RETURN")&&(!(reason instanceof String text)||text.trim().isEmpty()))throw new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(400,"El motivo de devolución es obligatorio.");apply(p);try{String result=jdbc.queryForObject("select salud_u.resolver_o_devolver_derivacion(?,?,?,?)",String.class,id,value,reason instanceof String text?text:null,followUp instanceof String text?text:null);return LegacyAvailabilityResponse.success(new com.fasterxml.jackson.databind.ObjectMapper().readValue(result,Map.class));}catch(org.springframework.dao.DataAccessException ex){String detail=ex.getMostSpecificCause().getMessage();if(detail!=null&&detail.contains("MOTIVO_DEVOLUCION_REQUERIDO"))throw new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(400,"El motivo de devolución es obligatorio.");if(detail!=null&&detail.contains("ATENCION_ESPECIALIZADA_REQUERIDA"))throw new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(409,"La derivación requiere una atención especializada cerrada.");throw new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(403,"La derivación no está disponible para este especialista.");}catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(400,"No se pudo resolver la derivación.");}}
}

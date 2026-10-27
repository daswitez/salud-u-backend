package bo.edu.uagrm.saludu.documents.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.time.Instant;
import java.time.LocalDate;
import java.util.Base64;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.dao.DataAccessException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.multipart.MultipartFile;

@Service
public class ClinicalDocumentService {
  private static final Set<String> MIMES=Set.of("application/pdf","image/jpeg","image/png","image/webp");
  private static final Set<String> TYPES=Set.of("BLOOD_CHEMISTRY","LAB_RESULT","RADIOGRAPH","PRESCRIPTION","CLINICAL_PHOTO","REFERRAL_DOCUMENT","OTHER");
  private final JdbcTemplate jdbc; private final DatabaseActorContext actors; private final AuditWriter auditWriter; private final Path root; private final Map<String,Grant> grants=new ConcurrentHashMap<>();
  public ClinicalDocumentService(JdbcTemplate jdbc, DatabaseActorContext actors, AuditWriter auditWriter, @Value("${salud-u.documents.root}") String root){this.jdbc=jdbc;this.actors=actors;this.auditWriter=auditWriter;this.root=Path.of(root).toAbsolutePath().normalize();}
  @Transactional public UUID upload(SessionPrincipal p, UUID patient, UUID encounter, String type, String description, LocalDate date, MultipartFile file){
    if(!p.roles().contains("REVIEW_DOCTOR")&&!p.roles().contains("SPECIALIST"))throw new AvailabilityException(403,"Solo un médico autorizado puede cargar documentos.");
    if(file==null||file.isEmpty()||file.getSize()>15L*1024*1024||!MIMES.contains(file.getContentType())||!TYPES.contains(type)||file.getOriginalFilename()==null||file.getOriginalFilename().isBlank())throw new AvailabilityException(400,"El archivo debe ser PDF, JPG, PNG o WEBP y pesar hasta 15 MiB.");
    actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));
    Map<String,Object> prepared;
    try { prepared=jdbc.queryForMap("select * from salud_u.preparar_carga_documento(?,?,?,?,?,?,?)",patient,encounter,type,file.getOriginalFilename(),file.getContentType(),date,description==null?null:description.trim().substring(0,Math.min(description.trim().length(),1000))); }
    catch(DataAccessException exception){throw new AvailabilityException(403,"No puedes adjuntar documentos a esta atención.");}
    UUID id=(UUID)prepared.get("id_documento"); Path destination=root.resolve((String)prepared.get("ruta_objeto")).normalize();
    if(!destination.startsWith(root))throw new AvailabilityException(400,"Ruta de archivo inválida.");
    Path temporary=null;
    try { Files.createDirectories(destination.getParent()); temporary=Files.createTempFile(destination.getParent(),"upload-",".tmp"); String checksum;
      try(InputStream in=file.getInputStream()){var digest=MessageDigest.getInstance("SHA-256"); try(var out=Files.newOutputStream(temporary)){byte[] b=new byte[8192]; for(int n;(n=in.read(b))>=0;){out.write(b,0,n);digest.update(b,0,n);}} checksum=java.util.HexFormat.of().formatHex(digest.digest());}
      if(Files.size(temporary)!=file.getSize()||!matchesDeclaredMime(temporary,file.getContentType()))throw new AvailabilityException(400,"El contenido o tamaño del archivo no coincide con su tipo declarado.");
      Files.move(temporary,destination,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING); deleteUnlessCommitted(destination); jdbc.query("select salud_u.finalizar_carga_documento(?,?,?)", resultSet -> {}, id,file.getSize(),checksum); auditWriter.append("DOCUMENTO_CLINICO_CARGADO","documento_clinico",id,AuditOutcome.SUCCESS,Map.of("tipoMime",file.getContentType(),"tamanoBytes",file.getSize())); return id;
    } catch(AvailabilityException e){ try{if(temporary!=null)Files.deleteIfExists(temporary);Files.deleteIfExists(destination);}catch(Exception ignored){} throw e;
    } catch(Exception e){ try{if(temporary!=null)Files.deleteIfExists(temporary);Files.deleteIfExists(destination);}catch(Exception ignored){} throw new AvailabilityException(400,"No se pudo guardar el archivo clínico."); }
  }
  // El archivo queda en disco antes del commit; si la transacción no se confirma (fallo de PostgreSQL al confirmar), se borra para no dejar archivos sin fila.
  private static void deleteUnlessCommitted(Path destination){
    if(!TransactionSynchronizationManager.isSynchronizationActive())return;
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization(){@Override public void afterCompletion(int status){if(status!=STATUS_COMMITTED)try{Files.deleteIfExists(destination);}catch(java.io.IOException ignored){}}});
  }
  @Transactional(readOnly=true) public String signedUrl(SessionPrincipal p,UUID id){
    if(!p.roles().contains("REVIEW_DOCTOR")&&!p.roles().contains("SPECIALIST"))throw new AvailabilityException(403,"Solo un médico autorizado puede descargar documentos.");
    Doc document=authorized(p,id); grants.entrySet().removeIf(entry->!entry.getValue().expires().isAfter(Instant.now())); String token=Base64.getUrlEncoder().withoutPadding().encodeToString(UUID.randomUUID().toString().getBytes()); grants.put(token,new Grant(p.id(),document,Instant.now().plusSeconds(60))); return "/api/medical/documents/"+id+"/content?token="+token;
  }
  @Transactional public java.util.List<DocumentMetadata> list(SessionPrincipal p,UUID encounter){
    if(!p.roles().contains("REVIEW_DOCTOR")&&!p.roles().contains("SPECIALIST"))throw new AvailabilityException(403,"Solo un médico autorizado puede consultar documentos.");
    actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));
    try {
      var result=jdbc.query("select * from salud_u.listar_documentos_encuentro_propio(?)",(r,n)->new DocumentMetadata(r.getObject("id",UUID.class),r.getString("tipo_documento"),r.getString("nombre_original"),r.getString("tipo_mime"),r.getLong("tamano_bytes"),r.getObject("fecha_estudio",LocalDate.class),r.getString("descripcion"),r.getObject("cargado_en",java.time.OffsetDateTime.class)),encounter);
      auditWriter.append("DOCUMENTOS_CLINICOS_CONSULTADOS","encuentro_clinico",encounter,AuditOutcome.SUCCESS,Map.of());return result;
    } catch(DataAccessException exception){throw new AvailabilityException(404,"No se encontró una atención accesible para consultar documentos.");}
  }
  @Transactional public Doc consume(SessionPrincipal p,UUID documentId,String token){
    if(!p.roles().contains("REVIEW_DOCTOR")&&!p.roles().contains("SPECIALIST"))throw new AvailabilityException(403,"Solo un médico autorizado puede descargar documentos.");
    authorized(p,documentId);
    Doc doc=consume(p.id(),documentId,token);auditWriter.append("DOCUMENTO_CLINICO_DESCARGADO","documento_clinico",documentId,AuditOutcome.SUCCESS,Map.of());return doc;
  }
  public Doc consume(UUID principalId, UUID documentId, String token){Grant g=grants.get(token); if(g==null||!g.expires().isAfter(Instant.now())||!g.principalId().equals(principalId)||!g.doc().id().equals(documentId)||!grants.remove(token,g))throw new AvailabilityException(404,"El enlace del archivo expiró."); return g.doc();}
  private Doc authorized(SessionPrincipal p,UUID id){
    actors.apply(new DatabaseActor(p.id(),Set.copyOf(p.roles())));
    try { var rows=jdbc.query("select * from salud_u.obtener_documento_autorizado(?)",(r,n)->new Doc(id,r.getString(1),r.getString(2),r.getString(3)),id); if(rows.isEmpty())throw new AvailabilityException(404,"El archivo no está disponible.");return rows.getFirst(); }
    catch(DataAccessException exception){throw new AvailabilityException(404,"El archivo no está disponible.");}
  }
  public Path path(Doc d){Path path=root.resolve(d.path()).normalize(); if(!path.startsWith(root))throw new AvailabilityException(404,"El archivo no está disponible."); return path;}
  private static boolean matchesDeclaredMime(Path file,String mime) throws java.io.IOException { byte[] h; try(InputStream in=Files.newInputStream(file)){h=in.readNBytes(12);} return switch(mime){case "application/pdf" -> starts(h,0,0x25,0x50,0x44,0x46,0x2d); case "image/jpeg" -> starts(h,0,0xff,0xd8,0xff); case "image/png" -> starts(h,0,0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a); case "image/webp" -> starts(h,0,0x52,0x49,0x46,0x46)&&starts(h,8,0x57,0x45,0x42,0x50); default -> false;};}
  private static boolean starts(byte[] bytes,int offset,int... expected){if(bytes.length<offset+expected.length)return false;for(int i=0;i<expected.length;i++)if((bytes[offset+i]&0xff)!=expected[i])return false;return true;}
  public record Doc(UUID id,String path,String mime,String name){} private record Grant(UUID principalId,Doc doc,Instant expires){}
  public record DocumentMetadata(UUID id,String documentType,String filename,String mimeType,long sizeBytes,LocalDate studyDate,String description,java.time.OffsetDateTime uploadedAt){}
}

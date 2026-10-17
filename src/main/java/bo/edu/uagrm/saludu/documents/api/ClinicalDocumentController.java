package bo.edu.uagrm.saludu.documents.api;

import bo.edu.uagrm.saludu.documents.application.ClinicalDocumentService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import java.nio.file.Files;
import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;
import org.springframework.core.io.FileSystemResource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

@RestController @RequestMapping("/api/medical/documents")
public class ClinicalDocumentController {
 private final ClinicalDocumentService service; public ClinicalDocumentController(ClinicalDocumentService service){this.service=service;}
 @PostMapping(consumes=MediaType.MULTIPART_FORM_DATA_VALUE) public ResponseEntity<LegacyAvailabilityResponse<Map<String,UUID>>> upload(@AuthenticationPrincipal SessionPrincipal p,@RequestParam UUID patientId,@RequestParam UUID encounterId,@RequestParam String documentType,@RequestParam(required=false) String description,@RequestParam(required=false) String studyDate,@RequestParam MultipartFile file){UUID id=service.upload(p,patientId,encounterId,documentType,description,studyDate==null||studyDate.isBlank()?null:LocalDate.parse(studyDate),file);return ResponseEntity.status(201).body(LegacyAvailabilityResponse.success(Map.of("id",id)));}
 @GetMapping("/{id}/download") public LegacyAvailabilityResponse<Map<String,String>> download(@AuthenticationPrincipal SessionPrincipal p,@PathVariable UUID id){return LegacyAvailabilityResponse.success(Map.of("url",service.signedUrl(p,id)));}
 @GetMapping("/{id}/content") public ResponseEntity<FileSystemResource> content(@AuthenticationPrincipal SessionPrincipal p,@PathVariable UUID id,@RequestParam String token){var doc=service.consume(p.id(),id,token);var path=service.path(doc);if(!Files.isRegularFile(path))throw new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(404,"El archivo no está disponible.");return ResponseEntity.ok().contentType(MediaType.parseMediaType(doc.mime())).header(HttpHeaders.CONTENT_DISPOSITION,ContentDisposition.attachment().filename(doc.name()).build().toString()).body(new FileSystemResource(path));}
}

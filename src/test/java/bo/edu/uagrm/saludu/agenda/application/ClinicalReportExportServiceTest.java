package bo.edu.uagrm.saludu.agenda.application;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;
import static org.junit.jupiter.api.Assertions.*;
class ClinicalReportExportServiceTest {
 final JdbcTemplate jdbc=mock(JdbcTemplate.class);final DatabaseActorContext actors=mock(DatabaseActorContext.class);final ClinicalReportFiles files=mock(ClinicalReportFiles.class);final ClinicalReportExportHistory history=mock(ClinicalReportExportHistory.class);final ObjectMapper json=new ObjectMapper();
 final SessionPrincipal principal=new SessionPrincipal(UUID.randomUUID(),"fe22@example.invalid","Médico",List.of("REVIEW_DOCTOR"));
 ClinicalReportExportService service(){return new ClinicalReportExportService(jdbc,json,actors,files,history);}
 ClinicalReportExportRequest request(){return ClinicalReportExportRequest.parse(Map.of("format","PDF","purpose","Consulta autorizada","filters",Map.of()),json);}
 @Test void moreThan10000IsRejectedBeforeRenderingOrPublishing() throws Exception {
  when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(Collections.nCopies(10001,Map.of()));var error=assertThrows(AvailabilityException.class,()->service().export(request(),principal));assertEquals(400,error.status());verifyNoInteractions(files,history);
 }
 @Test void zeroAnd10000UseOnlyRecalculatedCountAndPublishAfterRendering() throws Exception {
  UUID id=UUID.randomUUID();for(int size:new int[]{0,10000}){when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(Collections.nCopies(size,Map.of()));when(files.render(any(),anyList())).thenReturn(new byte[]{1,2,3});when(history.record(any(),eq("COMPLETED"),eq(size),anyString())).thenReturn(id);var file=service().export(request(),principal);assertEquals(size,file.rowCount());assertEquals(id,file.id());assertEquals(64,file.sha256().length());}
 }
 @Test void generationFailureRecordsFailedAndNeverCompleted() throws Exception {
  when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(List.of(Map.of()));when(files.render(any(),anyList())).thenThrow(new IOException("renderer interrupted"));var request=request();var error=assertThrows(ClinicalReportGenerationFailure.class,()->service().export(request,principal));assertEquals(1,error.rowCount());verifyNoInteractions(history);
 }
 @Test void auditFailurePreventsReturningGeneratedBytes() throws Exception {
  when(jdbc.query(anyString(),any(RowMapper.class),any(Object[].class))).thenReturn(List.of());when(files.render(any(),anyList())).thenReturn(new byte[]{1,2,3});when(history.record(any(),anyString(),anyInt(),anyString())).thenThrow(new org.springframework.dao.DataIntegrityViolationException("audit unavailable"));assertThrows(org.springframework.dao.DataAccessException.class,()->service().export(request(),principal));
 }
}

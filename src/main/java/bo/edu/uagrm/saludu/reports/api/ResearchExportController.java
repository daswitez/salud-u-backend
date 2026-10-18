package bo.edu.uagrm.saludu.reports.api;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/research/exports")
public class ResearchExportController {
    private static final List<String> COLUMNS = List.of("research_pseudonym", "encounter_month", "age_band", "career_code", "academic_period", "encounter_type", "specialty_code", "diagnosis_count", "vaccination_dose_count");
    private final JdbcTemplate jdbc; private final DatabaseActorContext actors; private final ObjectMapper json;
    public ResearchExportController(JdbcTemplate jdbc, DatabaseActorContext actors, ObjectMapper json) { this.jdbc = jdbc; this.actors = actors; this.json = json; }

    @PostMapping @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER')") @Transactional
    public ResponseEntity<byte[]> export(@RequestBody ResearchExportRequest request, @AuthenticationPrincipal SessionPrincipal principal) {
        if (request == null || request.purpose() == null || request.filters() == null || !Set.of("CSV", "XLSX").contains(request.format()) || request.purpose().trim().length() < 3 || request.purpose().trim().length() > 300) throw new AvailabilityException(400, "La exportación de investigación no es válida.");
        actors.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try {
            String filters = json.writeValueAsString(request.filters());
            List<Map<String, Object>> rows = jdbc.query("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))", (rs, ignored) -> { Map<String, Object> row = new LinkedHashMap<>(); row.put("research_pseudonym", rs.getString("seudonimo")); row.put("encounter_month", rs.getObject("mes_atencion", java.time.LocalDate.class)); row.put("age_band", rs.getString("rango_edad")); row.put("career_code", rs.getString("codigo_carrera")); row.put("academic_period", rs.getString("periodo_academico")); row.put("encounter_type", rs.getString("tipo_encuentro")); row.put("specialty_code", rs.getString("codigo_especialidad")); row.put("diagnosis_count", rs.getInt("cantidad_diagnosticos")); row.put("vaccination_dose_count", rs.getInt("cantidad_dosis_vacuna")); return row; }, filters);
            if (rows.size() > 10000) throw new AvailabilityException(400, "La exportación excede 10000 filas.");
            byte[] file = request.format().equals("CSV") ? zipCsv(rows) : workbook(rows);
            UUID exportId = jdbc.queryForObject("select salud_u.registrar_exportacion_investigacion(?, cast(? as jsonb), ?, ?)", UUID.class, request.purpose(), filters, request.format(), rows.size());
            String extension = request.format().equals("CSV") ? "zip" : "xlsx";
            String contentType = request.format().equals("CSV") ? "application/zip" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
            return ResponseEntity.ok().header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=investigacion-" + exportId + "." + extension).contentType(MediaType.parseMediaType(contentType)).body(file);
        } catch (AvailabilityException exception) { throw exception; }
        catch (DataAccessException exception) { throw new AvailabilityException(400, "No se pudo generar la exportación de investigación."); }
        catch (Exception exception) { throw new AvailabilityException(400, "No se pudo generar la exportación de investigación."); }
    }
    private static byte[] zipCsv(List<Map<String, Object>> rows) throws Exception { try (var out = new ByteArrayOutputStream(); var zip = new ZipOutputStream(out)) { zip.putNextEntry(new ZipEntry("research-data.csv")); zip.write(csv(COLUMNS, rows).getBytes(StandardCharsets.UTF_8)); zip.closeEntry(); zip.putNextEntry(new ZipEntry("dictionary.csv")); zip.write(dictionaryCsv().getBytes(StandardCharsets.UTF_8)); zip.closeEntry(); zip.finish(); return out.toByteArray(); } }
    private static byte[] workbook(List<Map<String, Object>> rows) throws Exception { try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) { var data = book.createSheet("Research data"); write(data, COLUMNS, rows); var dictionary = book.createSheet("Dictionary"); write(dictionary, List.of("column", "description"), dictionaryRows()); book.write(out); return out.toByteArray(); } }
    private static void write(org.apache.poi.ss.usermodel.Sheet sheet, List<String> headers, List<Map<String, Object>> rows) { var header = sheet.createRow(0); for (int i = 0; i < headers.size(); i++) header.createCell(i).setCellValue(headers.get(i)); for (int row = 0; row < rows.size(); row++) { var output = sheet.createRow(row + 1); for (int column = 0; column < headers.size(); column++) output.createCell(column).setCellValue(String.valueOf(rows.get(row).get(headers.get(column)) == null ? "" : rows.get(row).get(headers.get(column)))); } }
    private static String csv(List<String> headers, List<Map<String, Object>> rows) { StringBuilder value = new StringBuilder(String.join(",", headers)).append('\n'); for (Map<String, Object> row : rows) { for (int i = 0; i < headers.size(); i++) { if (i > 0) value.append(','); value.append('"').append(String.valueOf(row.get(headers.get(i)) == null ? "" : row.get(headers.get(i))).replace("\"", "\"\"")).append('"'); } value.append('\n'); } return value.toString(); }
    private static List<Map<String, Object>> dictionaryRows() { return List.of(entry("research_pseudonym", "MONTHLY-V1 rotating pseudonym; no reidentification key is exported."), entry("encounter_month", "Closed encounter date truncated to calendar month."), entry("age_band", "Age at encounter: UNDER_20, 20_24, 25_29, 30_PLUS or UNKNOWN."), entry("career_code", "Academic career code at encounter."), entry("academic_period", "Academic period at encounter."), entry("encounter_type", "INITIAL or SPECIALTY."), entry("specialty_code", "Specialty code, when applicable."), entry("diagnosis_count", "Count of diagnoses; never diagnosis text."), entry("vaccination_dose_count", "Total recorded vaccine doses for the pseudonymous subject.")); }
    private static Map<String, Object> entry(String column, String description) { return Map.of("column", column, "description", description); }
    private static String dictionaryCsv() { return csv(List.of("column", "description"), dictionaryRows()); }
    public record ResearchExportRequest(String purpose, Map<String, Object> filters, String format) { }
}

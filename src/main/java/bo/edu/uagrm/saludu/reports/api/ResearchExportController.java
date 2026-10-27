package bo.edu.uagrm.saludu.reports.api;

import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
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
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/research/exports")
public class ResearchExportController {
    private static final List<String> COLUMNS = List.of("research_pseudonym", "encounter_month", "age_band", "sex", "career_code", "academic_period", "encounter_type", "specialty_code", "diagnosis_count", "vaccination_dose_count");
    private static final Set<String> NUMERIC = Set.of("diagnosis_count", "vaccination_dose_count");
    private final JdbcTemplate jdbc; private final DatabaseActorContext actors; private final ObjectMapper json;
    public ResearchExportController(JdbcTemplate jdbc, DatabaseActorContext actors, ObjectMapper json) { this.jdbc = jdbc; this.actors = actors; this.json = json; }

    /** El archivo se genera completo antes de responder; si algo falla no se registra procedencia ni se envían bytes parciales. */
    @PostMapping @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER')") @Transactional
    public ResponseEntity<byte[]> export(@RequestBody ResearchExportRequest request, @AuthenticationPrincipal SessionPrincipal principal) {
        if (request == null || request.purpose() == null || request.purpose().trim().length() < 3 || request.purpose().trim().length() > 300) throw new AvailabilityException(400, "Indica la finalidad de la exportación (entre 3 y 300 caracteres).");
        if (!Set.of("CSV", "XLSX").contains(request.format())) throw new AvailabilityException(400, "Elige un formato de exportación válido (CSV o XLSX).");
        actors.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        String filters; byte[] file; List<Map<String, Object>> rows;
        try {
            filters = json.writeValueAsString(request.filters() == null ? Map.of() : request.filters());
            rows = jdbc.query("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb)) limit 10001", (rs, ignored) -> { Map<String, Object> row = new LinkedHashMap<>(); row.put("research_pseudonym", rs.getString("seudonimo")); row.put("encounter_month", rs.getObject("mes_atencion", java.time.LocalDate.class)); row.put("age_band", rs.getString("rango_edad")); row.put("sex", rs.getString("sexo")); row.put("career_code", rs.getString("codigo_carrera")); row.put("academic_period", rs.getString("periodo_academico")); row.put("encounter_type", rs.getString("tipo_encuentro")); row.put("specialty_code", rs.getString("codigo_especialidad")); row.put("diagnosis_count", rs.getInt("cantidad_diagnosticos")); row.put("vaccination_dose_count", rs.getInt("cantidad_dosis_vacuna")); return row; }, filters);
        } catch (DataAccessException exception) { throw translated(exception); }
        catch (com.fasterxml.jackson.core.JsonProcessingException exception) { throw new AvailabilityException(400, "Los filtros de investigación no son válidos."); }
        if (rows.size() > 10000) throw new AvailabilityException(400, "La exportación supera 10.000 atenciones. Acota el período o agrega filtros.");
        try { file = request.format().equals("CSV") ? zipCsv(rows) : workbook(rows); }
        catch (Exception exception) { throw new AvailabilityException(500, "No se pudo generar el archivo completo. Puedes reintentar o elegir otro formato."); }
        String sha256 = sha256(file); UUID exportId; String policy; String excluded;
        try {
            exportId = jdbc.queryForObject("select salud_u.registrar_exportacion_investigacion(?, cast(? as jsonb), ?, ?, ?)", UUID.class, request.purpose(), filters, request.format(), rows.size(), sha256);
            policy = jdbc.queryForObject("select (r ->> 'policyVersion') || ';' || (r ->> 'policyMonth') from salud_u.obtener_exportacion_investigacion(?) r", String.class, exportId);
            // A-03: pacientes con atenciones dentro de los filtros que quedaron fuera por responder No o por no haber respondido.
            excluded = jdbc.queryForObject("select (r ->> 'excludedDeclined') || ';' || (r ->> 'excludedUnanswered') from salud_u.obtener_exportacion_investigacion(?) r", String.class, exportId);
        } catch (DataAccessException exception) { throw translated(exception); }
        boolean csv = request.format().equals("CSV");
        return ResponseEntity.ok().header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=investigacion-" + exportId + (csv ? ".zip" : ".xlsx")).contentType(MediaType.parseMediaType(csv ? "application/zip" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))
            .header("X-Export-Id", exportId.toString()).header("X-Export-Row-Count", Integer.toString(rows.size())).header("X-Content-SHA256", sha256).header("X-Pseudonym-Policy", policy)
            .header("X-Excluded-Declined", excluded == null ? "0" : excluded.split(";")[0]).header("X-Excluded-Unanswered", excluded == null ? "0" : excluded.split(";")[1]).body(file);
    }

    /** Constancia de una exportación propia para confirmar finalidad, filtros y archivo después de recargar. */
    @GetMapping("/{id}") @PreAuthorize("hasAnyRole('ADMINISTRATIVE','REPORTING_OFFICER')") @Transactional(readOnly = true)
    public LegacyAvailabilityResponse<Object> provenance(@PathVariable UUID id, @AuthenticationPrincipal SessionPrincipal principal) {
        actors.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
        try { return LegacyAvailabilityResponse.success(json.readValue(jdbc.queryForObject("select salud_u.obtener_exportacion_investigacion(?)::text", String.class, id), Object.class)); }
        catch (DataAccessException exception) { throw translated(exception); }
        catch (com.fasterxml.jackson.core.JsonProcessingException exception) { throw new AvailabilityException(500, "No se pudo leer la constancia de exportación."); }
    }

    private static AvailabilityException translated(DataAccessException exception) {
        String detail = exception.getMostSpecificCause().getMessage();
        if (detail != null && detail.contains("FILTROS_INVESTIGACION_INVALIDOS")) return new AvailabilityException(400, "Revisa los filtros: usa fechas válidas (desde no posterior a hasta) y opciones de los catálogos.");
        if (detail != null && detail.contains("EXPORTACION_INVESTIGACION_INVALIDA")) return new AvailabilityException(400, "La exportación de investigación no es válida.");
        if (detail != null && detail.contains("EXPORTACION_INVESTIGACION_NO_ENCONTRADA")) return new AvailabilityException(404, "No existe una exportación tuya con ese identificador.");
        if (detail != null && detail.contains("Se requiere el rol")) return new AvailabilityException(403, "No tienes permiso para exportar datos de investigación.");
        return new AvailabilityException(500, "No se pudo completar la exportación de investigación. Puedes reintentar.");
    }
    private static String sha256(byte[] bytes) { try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); } catch (java.security.NoSuchAlgorithmException exception) { throw new IllegalStateException(exception); } }
    private static byte[] zipCsv(List<Map<String, Object>> rows) throws Exception { try (var out = new ByteArrayOutputStream(); var zip = new ZipOutputStream(out)) { zip.putNextEntry(new ZipEntry("research-data.csv")); zip.write(csv(COLUMNS, rows).getBytes(StandardCharsets.UTF_8)); zip.closeEntry(); zip.putNextEntry(new ZipEntry("dictionary.csv")); zip.write(dictionaryCsv().getBytes(StandardCharsets.UTF_8)); zip.closeEntry(); zip.finish(); return out.toByteArray(); } }
    private static byte[] workbook(List<Map<String, Object>> rows) throws Exception { try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) { var data = book.createSheet("Research data"); write(data, COLUMNS, rows); var dictionary = book.createSheet("Dictionary"); write(dictionary, List.of("column", "description"), dictionaryRows()); book.write(out); return out.toByteArray(); } }
    private static void write(org.apache.poi.ss.usermodel.Sheet sheet, List<String> headers, List<Map<String, Object>> rows) { var header = sheet.createRow(0); for (int i = 0; i < headers.size(); i++) header.createCell(i).setCellValue(headers.get(i)); for (int row = 0; row < rows.size(); row++) { var output = sheet.createRow(row + 1); for (int column = 0; column < headers.size(); column++) { Object value = rows.get(row).get(headers.get(column)); if (NUMERIC.contains(headers.get(column)) && value instanceof Number number) output.createCell(column).setCellValue(number.doubleValue()); else output.createCell(column).setCellValue(value == null ? "" : value.toString()); } } }
    // BOM para que hojas de cálculo lean UTF-8; un texto que empieza con = + - @ se neutraliza para no ejecutarse como fórmula.
    private static String csv(List<String> headers, List<Map<String, Object>> rows) { StringBuilder value = new StringBuilder("﻿").append(String.join(",", headers)).append('\n'); for (Map<String, Object> row : rows) { for (int i = 0; i < headers.size(); i++) { if (i > 0) value.append(','); String cell = row.get(headers.get(i)) == null ? "" : String.valueOf(row.get(headers.get(i))); if (!cell.isEmpty() && "=+-@\t\r".indexOf(cell.charAt(0)) >= 0) cell = "'" + cell; value.append('"').append(cell.replace("\"", "\"\"")).append('"'); } value.append('\n'); } return value.toString(); }
    private static List<Map<String, Object>> dictionaryRows() { return List.of(
        entry("research_pseudonym", "Seudónimo MONTHLY-V1 (R- y 20 caracteres): estable para un mismo estudiante durante el mes calendario de exportación en Bolivia y rota al mes siguiente. No se exporta clave de reidentificación."),
        entry("encounter_month", "Primer día del mes (hora de Bolivia) en que se cerró la atención; nunca la fecha exacta."),
        entry("age_band", "Edad al cierre de la atención: UNDER_20, 20_24, 25_29, 30_PLUS o UNKNOWN si no hay fecha de nacimiento."),
        entry("sex", "Sexo registrado: FEMALE, MALE, NOT_RECORDED (no lo declaró) o UNKNOWN si nunca se registró."),
        entry("career_code", "Código de la carrera de la matrícula vigente al cierre; UNKNOWN si no había matrícula."),
        entry("academic_period", "Período académico de esa matrícula; UNKNOWN si no había matrícula."),
        entry("encounter_type", "INITIAL (revisión médica) o SPECIALTY (atención de especialidad)."),
        entry("specialty_code", "Código de la especialidad para atenciones SPECIALTY; vacío en INITIAL."),
        entry("diagnosis_count", "Cantidad de diagnósticos registrados en la atención; nunca su texto."),
        entry("vaccination_dose_count", "Total de dosis de vacuna registradas para el seudónimo a la fecha de exportación.")); }
    private static Map<String, Object> entry(String column, String description) { return Map.of("column", column, "description", description); }
    private static String dictionaryCsv() { return csv(List.of("column", "description"), dictionaryRows()); }
    public record ResearchExportRequest(String purpose, Map<String, Object> filters, String format) { }
}

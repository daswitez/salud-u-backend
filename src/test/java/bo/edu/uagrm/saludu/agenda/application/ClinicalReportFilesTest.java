package bo.edu.uagrm.saludu.agenda.application;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.apache.poi.ss.usermodel.CellType;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
class ClinicalReportFilesTest {
 final ObjectMapper json=new ObjectMapper();final ClinicalReportFiles files=new ClinicalReportFiles(json);
 ClinicalReportExportRequest request(String format){return ClinicalReportExportRequest.parse(Map.of("format",format,"purpose","Seguimiento institucional","filters",Map.of("search","Ácido"),"columns",List.of("patient_name","carnet","diagnoses","habits","assessment","birth_date"),"groupBy",List.of("specialty")),json);}
 Map<String,Object> row() throws Exception {var row=new LinkedHashMap<String,Object>();row.put("encounter_id",UUID.randomUUID());row.put("closed_at",OffsetDateTime.parse("2026-10-26T03:59:00Z"));row.put("specialty_name",null);row.put("patient_name","Pérez, Ana");row.put("carnet","00123");row.put("diagnoses","Ácido \"confirmado\"\nSegunda línea");row.put("habits",json.readTree("{\"tabaco\":\"SI\",\"actividadFisica\":\"NO\",\"alimentacion\":\"ADECUADA\"}"));row.put("assessment",null);row.put("birth_date",LocalDate.parse("2002-01-15"));return row;}
 @Test void csvXlsxAndPdfContainSameSelectedGroupedHistoricalContent() throws Exception {
  var row=row();var data=files.data(request("CSV"),List.of(row));assertEquals(List.of("Grupo","Paciente","Carnet","Diagnósticos","Hábitos","Evaluación","Fecha de nacimiento"),data.headers());
  var csv=new String(files.render(request("CSV"),List.of(row)),StandardCharsets.UTF_8);assertTrue(csv.startsWith("\uFEFF"));assertTrue(csv.contains("\"Pérez, Ana\""));assertTrue(csv.contains("\"Ácido \"\"confirmado\"\"\nSegunda línea\""));
  byte[] xlsx=files.render(request("XLSX"),List.of(row));try(var book=new XSSFWorkbook(new ByteArrayInputStream(xlsx))){var sheet=book.getSheetAt(0);assertEquals(2,book.getAllPictures().size());assertNotNull(sheet.getPaneInformation());var actual=sheet.getRow(sheet.getLastRowNum());for(int i=0;i<data.headers().size();i++){assertEquals(data.rows().getFirst().get(i),actual.getCell(i).getStringCellValue());assertEquals(CellType.STRING,actual.getCell(i).getCellType());}}
  try(var pdf=Loader.loadPDF(files.render(request("PDF"),List.of(row)))){assertTrue(pdf.getNumberOfPages()>0);String text=new PDFTextStripper().getText(pdf).replaceAll("\\s+","");for(var value:data.rows().getFirst())assertTrue(text.contains(value.replaceAll("\\s+","")),value);assertTrue(text.contains("UAGRM"));assertTrue(text.contains("Seguimientoinstitucional"));}
 }
 @Test void longValuesAreContinuedWithoutTruncationAndPdfRepeatsHeadersAcrossPages() throws Exception {
  var row=row();String longText="Línea clínica extensa ".repeat(1600)+"FIN_CONTENIDO_FE22";row.put("diagnoses",longText);var q=ClinicalReportExportRequest.parse(Map.of("format","XLSX","purpose","Validar contenido extenso","filters",Map.of(),"columns",List.of("patient_name","diagnoses")),json);var data=files.data(q,List.of(row));assertEquals("Parte",data.headers().getLast());assertTrue(data.rows().size()>1);assertEquals(longText,String.join("",data.rows().stream().map(r->r.get(1)).toList()));
  try(var book=new XSSFWorkbook(new ByteArrayInputStream(files.render(q,List.of(row))))){assertTrue(book.getSheetAt(0).getLastRowNum()>10);}
  try(var pdf=Loader.loadPDF(files.render(new ClinicalReportExportRequest("PDF",q.purpose(),q.query()),List.of(row)))){assertTrue(pdf.getNumberOfPages()>1);assertTrue(new PDFTextStripper().getText(pdf).contains("FIN_CONTENIDO_FE22"));}
  List<Map<String,Object>> many=new ArrayList<>();for(int i=0;i<140;i++){var r=row();r.put("patient_name","Paciente "+i);many.add(r);}try(var pdf=Loader.loadPDF(files.render(request("PDF"),many))){assertTrue(pdf.getNumberOfPages()>1);String text=new PDFTextStripper().getText(pdf);assertTrue(text.contains("Paciente 139"));assertTrue(text.contains("Documento clínico confidencial"));}
 }
 @Test void emptyAndFormulaLikeValuesAreSafeAndExplicit() throws Exception {
  assertEquals("\"'=2+2\"",ClinicalReportFiles.csvCell("=2+2"));assertEquals("\"'  @SUM(A1)\"",ClinicalReportFiles.csvCell("  @SUM(A1)"));assertEquals("\"'\t=1\"",ClinicalReportFiles.csvCell("\t=1"));
  List<String> terms=new ArrayList<>();for(int i=0;i<15;i++)terms.add("í".repeat(196)+i+"🧬");var unicode=ClinicalReportExportRequest.parse(Map.of("format","CSV","purpose","Criterios Unicode","filters",Map.of("allergies",terms)),json);String encoded=new String(files.render(unicode,List.of()),StandardCharsets.UTF_8);assertEquals(15,encoded.codePoints().filter(c->c==0x1F9EC).count());
  try(var book=new XSSFWorkbook(new ByteArrayInputStream(files.render(new ClinicalReportExportRequest("XLSX",unicode.purpose(),unicode.query()),List.of())))){long count=0;for(var cells:book.getSheetAt(0))for(var c:cells)count+=c.getStringCellValue().codePoints().filter(v->v==0x1F9EC).count();assertEquals(15,count);}
  for(String format:List.of("CSV","XLSX","PDF"))assertTrue(files.render(request(format),List.of()).length>10);
  var row=row();row.put("patient_name","=HYPERLINK(\"evil\")");try(var book=new XSSFWorkbook(new ByteArrayInputStream(files.render(request("XLSX"),List.of(row))))){var cell=book.getSheetAt(0).getRow(book.getSheetAt(0).getLastRowNum()).getCell(1);assertEquals(CellType.STRING,cell.getCellType());assertEquals(row.get("patient_name"),cell.getStringCellValue());}
 }
}

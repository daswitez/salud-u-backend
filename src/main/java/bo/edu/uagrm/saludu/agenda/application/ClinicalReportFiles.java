package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.ss.util.*;
import org.apache.poi.xssf.usermodel.*;
import org.apache.pdfbox.pdmodel.*;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.font.*;
import org.apache.pdfbox.pdmodel.graphics.image.PDImageXObject;
import org.springframework.stereotype.Component;

@Component
public class ClinicalReportFiles {
    public record Data(List<List<String>> metadata,List<String> headers,List<List<String>> rows){}
    private static final Map<String,String> LABELS;
    static{Map<String,String> labels=new LinkedHashMap<>();String[] names={"Fecha","Paciente","Carnet","Tipo","Especialidad","Diagnósticos","Alergias","Antecedentes","Hábitos","Motivo","Evaluación","Indicaciones","Seguimiento","Fecha de nacimiento","Ficha de especialidad"};for(int i=0;i<names.length;i++)labels.put(ClinicalReportQuery.COLUMNS.get(i),names[i]);LABELS=Map.copyOf(labels);}
    private static final Map<String,String> DIMENSIONS=Map.of("day","Día","month","Mes","encounterType","Tipo de atención","specialty","Especialidad");
    private static final ZoneId BOLIVIA=ZoneId.of("America/La_Paz");
    private final ObjectMapper json;
    public ClinicalReportFiles(ObjectMapper json){this.json=json;}
    public byte[] render(ClinicalReportExportRequest request,List<Map<String,Object>> rows) throws IOException {
        Data data=data(request,rows);
        return switch(request.format()){case "CSV"->csv(data);case "XLSX"->xlsx(data);case "PDF"->pdf(data);default->throw new IllegalArgumentException("Formato inválido");};
    }
    public Data data(ClinicalReportExportRequest request,List<Map<String,Object>> rows){
        var q=request.query();List<String> headers=new ArrayList<>();if(!q.groupBy().isEmpty())headers.add("Grupo");headers.addAll(q.columns().stream().map(LABELS::get).toList());
        Map<UUID,Map<String,Object>> byId=new LinkedHashMap<>();rows.forEach(r->byId.put((UUID)r.get("encounter_id"),r));
        List<List<String>> values=new ArrayList<>();
        if(q.groupBy().isEmpty())for(var row:rows)values.add(values(q,row,null));else {
            @SuppressWarnings("unchecked") var groups=(List<Map<String,Object>>)q.presentation(rows).get("groups");
            for(var group:groups){@SuppressWarnings("unchecked") var key=(List<Object>)group.get("key");StringJoiner title=new StringJoiner(" · ");for(int i=0;i<key.size();i++)title.add(DIMENSIONS.get(q.groupBy().get(i))+": "+groupValue(key.get(i)));String name=title+" · "+group.get("count")+" atención(es)";
                for(Object id:(List<?>)group.get("encounterIds"))values.add(values(q,byId.get(id),name));
            }
        }
        // Excel's 32,767-character limit is addressed identically in all three formats.
        boolean continued=values.stream().flatMap(Collection::stream).anyMatch(v->v.length()>30000);
        if(continued){headers.add("Parte");List<List<String>> expanded=new ArrayList<>();for(var row:values){List<List<String>> chunks=row.stream().map(ClinicalReportFiles::chunks).toList();int parts=chunks.stream().mapToInt(List::size).max().orElse(1);for(int n=0;n<parts;n++){List<String> line=new ArrayList<>();for(var cell:chunks)line.add(n<cell.size()?cell.get(n):"");line.add((n+1)+"/"+parts);expanded.add(line);}}values=expanded;}
        List<List<String>> metadata=new ArrayList<>();metadata.add(List.of("Reporte","Reporte de atenciones clínicas"));metadata.add(List.of("Institución","Centro de Especialidades Médicas · Facultad de Ciencias de la Salud Humana · UAGRM"));metadata.add(List.of("Período","Desde "+Objects.toString(q.filters().get("from"),"últimos 30 días")+" hasta "+Objects.toString(q.filters().get("to"),"hoy")+" (Bolivia)"));metadata.add(List.of("Finalidad",request.purpose()));metadata.add(List.of("Atenciones",String.valueOf(rows.size())));metadata.add(List.of("Filtros",filterText(q.filters())));metadata.add(List.of("Columnas",String.join(" · ",q.columns().stream().map(LABELS::get).toList())));metadata.add(List.of("Agrupaciones",q.groupBy().isEmpty()?"Sin agrupación":String.join(" · ",q.groupBy().stream().map(DIMENSIONS::get).toList())));
        List<List<String>> completeMetadata=new ArrayList<>();for(var meta:metadata){List<String> parts=chunks(meta.get(1),1000);for(int n=0;n<parts.size();n++)completeMetadata.add(List.of(meta.get(0)+(n==0?"":" (continuación "+(n+1)+")"),parts.get(n)));}
        return new Data(completeMetadata,headers,values);
    }
    private List<String> values(ClinicalReportQuery q,Map<String,Object> row,String group){List<String> values=new ArrayList<>();if(group!=null)values.add(group);q.columns().forEach(c->values.add(cell(row,c)));return values;}
    public String cell(Map<String,Object> row,String key){Object value=row.get(key);if(value==null)return "—";
        if(key.equals("closed_at"))return ((OffsetDateTime)value).atZoneSameInstant(BOLIVIA).format(DateTimeFormatter.ofPattern("dd/MM/uuuu"));
        if(key.equals("birth_date"))return ((LocalDate)value).format(DateTimeFormatter.ofPattern("dd/MM/uuuu"));
        if(key.equals("encounter_type"))return groupValue(value);
        if(key.equals("habits"))return habits(json.valueToTree(value));
        if(key.equals("specialty_history"))return structured(json.valueToTree(value),"");
        String text=value.toString();return text.isEmpty()?"—":text;
    }
    private static String groupValue(Object v){return v==null?"Sin especialidad":v.equals("INITIAL")?"Revisión":v.equals("SPECIALTY")?"Especialidad":v.toString();}
    private static String habits(JsonNode h){List<String> lines=new ArrayList<>();for(var e:List.of(Map.entry("tabaco","Tabaco"),Map.entry("alcohol","Alcohol"),Map.entry("actividadFisica","Actividad física"))){String v=h.path(e.getKey()).asText();if(v.equals("SI")||v.equals("NO"))lines.add(e.getValue()+": "+(v.equals("SI")?"sí":"no"));}String diet=h.path("alimentacion").asText();if(!diet.isBlank())lines.add("Alimentación: "+diet.toLowerCase(Locale.ROOT));String notes=h.path("notes").asText();if(!notes.isBlank())lines.add(notes);return lines.isEmpty()?"—":String.join(" · ",lines);}
    private static String structured(JsonNode v,String prefix){if(v.isObject()){List<String> out=new ArrayList<>();v.fields().forEachRemaining(f->out.add(structured(f.getValue(),prefix+f.getKey().replaceAll("([a-z])([A-Z])","$1 $2")+": ")));return String.join(" · ",out);}if(v.isArray()){List<String> out=new ArrayList<>();v.forEach(x->out.add(structured(x,prefix)));return out.isEmpty()?prefix+"No registrado":String.join(" · ",out);}return prefix+(v.isNull()||v.asText().isBlank()?"No registrado":v.isBoolean()?v.asBoolean()?"Sí":"No":v.asText());}
    private static String filterText(Map<String,Object> filters){Map<String,String> labels=Map.of("from","Desde","to","Hasta","specialtyId","Especialidad","encounterType","Tipo","diagnosis","Diagnóstico","allergies","Alergias","histories","Antecedentes","habitTerms","Hábitos","positiveHabits","Hábitos afirmativos","search","Búsqueda");List<String> parts=new ArrayList<>();filters.forEach((key,value)->{if(value instanceof List<?> list){if(!list.isEmpty())parts.add(labels.get(key)+": "+String.join(", ",list.stream().map(Object::toString).map(v->switch(v){case "tobacco"->"Tabaco";case "physicalActivity"->"Actividad física";case "alcohol"->"Alcohol";default->v;}).toList()));}else if(value!=null)parts.add(labels.get(key)+": "+groupValue(value));});return parts.isEmpty()?"Sin criterios adicionales":String.join(" · ",parts);}
    private static List<String> chunks(String value){return chunks(value,30000);}
    private static List<String> chunks(String value,int limit){List<String> out=new ArrayList<>();if(value.isEmpty())return List.of("");for(int start=0;start<value.length();){int end=Math.min(value.length(),start+limit);if(end<value.length()&&Character.isHighSurrogate(value.charAt(end-1)))end--;out.add(value.substring(start,end));start=end;}return out;}
    public static String csvCell(String value){String first=value.stripLeading();if(!first.isEmpty()&&"=+-@".indexOf(first.charAt(0))>=0||value.startsWith("\t")||value.startsWith("\r"))value="'"+value;return '"'+value.replace("\"","\"\"")+'"';}
    private static byte[] csv(Data data){StringBuilder text=new StringBuilder("\uFEFF");for(var meta:data.metadata())text.append(String.join(",",meta.stream().map(ClinicalReportFiles::csvCell).toList())).append("\r\n");text.append("\r\n").append(String.join(",",data.headers().stream().map(ClinicalReportFiles::csvCell).toList())).append("\r\n");for(var row:data.rows())text.append(String.join(",",row.stream().map(ClinicalReportFiles::csvCell).toList())).append("\r\n");return text.toString().getBytes(StandardCharsets.UTF_8);}
    private static byte[] resource(String path) throws IOException {try(var in=ClinicalReportFiles.class.getResourceAsStream(path)){if(in==null)throw new IOException("Recurso institucional no disponible");return in.readAllBytes();}}
    private static byte[] xlsx(Data data) throws IOException {
        try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()){
            var sheet=book.createSheet("Atenciones");int last=Math.max(6,data.headers().size()-1);for(int i=0;i<=last;i++)sheet.setColumnWidth(i,Math.min(255*256,(i==0?30:35)*256));sheet.createRow(0).setHeightInPoints(46);
            var drawing=sheet.createDrawingPatriarch();for(int i=0;i<2;i++){int picture=book.addPicture(resource("/branding/"+(i==0?"fcsh-uagrm-emblem.png":"centro-especialidades-emblem.png")),Workbook.PICTURE_TYPE_PNG);var anchor=book.getCreationHelper().createClientAnchor();anchor.setCol1(i==0?0:last);anchor.setRow1(0);anchor.setCol2(i==0?0:last);anchor.setRow2(0);anchor.setDx2(org.apache.poi.util.Units.toEMU(44));anchor.setDy2(org.apache.poi.util.Units.toEMU(44));drawing.createPicture(anchor,picture);}
            var head=book.createCellStyle();head.setFillForegroundColor(IndexedColors.DARK_BLUE.getIndex());head.setFillPattern(FillPatternType.SOLID_FOREGROUND);head.setWrapText(true);var bold=book.createFont();bold.setBold(true);bold.setColor(IndexedColors.WHITE.getIndex());head.setFont(bold);
            var style=book.createCellStyle();style.setWrapText(true);style.setVerticalAlignment(VerticalAlignment.TOP);var alternate=book.createCellStyle();alternate.cloneStyleFrom(style);alternate.setFillForegroundColor(IndexedColors.PALE_BLUE.getIndex());alternate.setFillPattern(FillPatternType.SOLID_FOREGROUND);
            int n=1;for(var meta:data.metadata()){var row=sheet.createRow(n);row.setHeightInPoints(Math.min(409,Math.max(30,14*(float)Math.ceil(meta.get(1).length()/(last*30.0)))));row.createCell(0).setCellValue(meta.get(0));row.createCell(1).setCellValue(meta.get(1));row.getCell(1).setCellStyle(style);sheet.addMergedRegion(new CellRangeAddress(n,n,1,last));n++;}
            n++;int headerIndex=n;var header=sheet.createRow(n++);header.setHeightInPoints(32);for(int i=0;i<data.headers().size();i++){var c=header.createCell(i,CellType.STRING);c.setCellValue(data.headers().get(i));c.setCellStyle(head);}
            for(var values:data.rows()){var row=sheet.createRow(n++);row.setHeightInPoints(60);for(int i=0;i<values.size();i++){var c=row.createCell(i,CellType.STRING);c.setCellValue(values.get(i));c.setCellStyle(n%2==0?style:alternate);}}
            sheet.createFreezePane(0,headerIndex+1);sheet.setAutoFilter(new CellRangeAddress(headerIndex,Math.max(headerIndex,n-1),0,data.headers().size()-1));sheet.setRepeatingRows(new CellRangeAddress(headerIndex,headerIndex,-1,-1));sheet.getPrintSetup().setLandscape(true);sheet.setFitToPage(true);sheet.getPrintSetup().setFitWidth((short)1);sheet.getPrintSetup().setFitHeight((short)0);sheet.getFooter().setCenter("Documento clínico confidencial · Página &P de &N");book.write(out);return out.toByteArray();
        }
    }
    private static byte[] pdf(Data data) throws IOException {
        try(var doc=new PDDocument();var out=new ByteArrayOutputStream()){
            var regular=PDType0Font.load(doc,new ByteArrayInputStream(resource("/fonts/DejaVuSans.ttf")));var bold=PDType0Font.load(doc,new ByteArrayInputStream(resource("/fonts/DejaVuSans-Bold.ttf")));
            try(var layout=new PdfTable(doc,regular,bold,data)){layout.start();for(var meta:data.metadata())layout.paragraph(meta.get(0)+": "+meta.get(1));layout.table();}
            doc.save(out);return out.toByteArray();
        }
    }
    private static final class PdfTable implements AutoCloseable {
        final PDDocument doc;final PDType0Font font,bold;final Data data;final PDImageXObject faculty,center;PDPageContentStream stream;float y;int page;boolean table;
        static final float WIDTH=1190,HEIGHT=842,MARGIN=30,SIZE=7,LINE=9;
        PdfTable(PDDocument doc,PDType0Font font,PDType0Font bold,Data data) throws IOException {this.doc=doc;this.font=font;this.bold=bold;this.data=data;faculty=PDImageXObject.createFromByteArray(doc,resource("/branding/fcsh-uagrm-emblem.png"),"Facultad");center=PDImageXObject.createFromByteArray(doc,resource("/branding/centro-especialidades-emblem.png"),"Centro");}
        void start() throws IOException {
            if(stream!=null)stream.close();var p=new PDPage(new PDRectangle(WIDTH,HEIGHT));doc.addPage(p);stream=new PDPageContentStream(doc,p);page++;
            stream.drawImage(faculty,MARGIN,HEIGHT-62,40,40);stream.drawImage(center,WIDTH-MARGIN-40,HEIGHT-62,40,40);
            stream.setNonStrokingColor(new java.awt.Color(30,57,114));stream.addRect(90,HEIGHT-57,WIDTH-180,32);stream.fill();text("REPORTE DE ATENCIONES CLÍNICAS",100,HEIGHT-45,bold,15,java.awt.Color.WHITE);text("Centro de Especialidades Médicas · Facultad de Ciencias de la Salud Humana · UAGRM",90,HEIGHT-74,font,9,java.awt.Color.DARK_GRAY);text("Documento clínico confidencial · Página "+page,MARGIN,15,font,8,java.awt.Color.DARK_GRAY);y=HEIGHT-92;if(table)header();
        }
        void paragraph(String text) throws IOException {for(String line:wrap(text,WIDTH-MARGIN*2,font,9)){if(y<50)start();text(line,MARGIN,y,font,9,java.awt.Color.BLACK);y-=12;}y-=5;}
        void table() throws IOException {table=true;if(y<90)start();else header();for(var row:data.rows())row(row);if(data.rows().isEmpty())paragraph("No hay atenciones para estos filtros.");}
        void header() throws IOException {float col=(WIDTH-MARGIN*2)/data.headers().size();List<List<String>> lines=data.headers().stream().map(s->wrap(s,col-8,bold,SIZE)).toList();int height=lines.stream().mapToInt(List::size).max().orElse(1);float h=height*LINE+10;stream.setNonStrokingColor(new java.awt.Color(215,25,32));stream.addRect(MARGIN,y-h,WIDTH-MARGIN*2,h);stream.fill();for(int i=0;i<lines.size();i++)for(int j=0;j<lines.get(i).size();j++)text(lines.get(i).get(j),MARGIN+i*col+4,y-10-j*LINE,bold,SIZE,java.awt.Color.WHITE);y-=h;}
        void row(List<String> row) throws IOException {float col=(WIDTH-MARGIN*2)/row.size();List<List<String>> lines=row.stream().map(s->wrap(s,col-8,font,SIZE)).toList();int total=lines.stream().mapToInt(List::size).max().orElse(1),offset=0;while(offset<total){if(y<65)start();int take=Math.min(total-offset,Math.max(1,(int)((y-45)/LINE)-1));float h=take*LINE+8;stream.setStrokingColor(new java.awt.Color(216,224,237));stream.setLineWidth(.3f);for(int i=0;i<lines.size();i++){stream.addRect(MARGIN+i*col,y-h,col,h);stream.stroke();for(int j=0;j<take&&offset+j<lines.get(i).size();j++)text(lines.get(i).get(offset+j),MARGIN+i*col+4,y-10-j*LINE,font,SIZE,java.awt.Color.BLACK);}y-=h;offset+=take;if(offset<total)start();}}
        void text(String value,float x,float y,PDFont f,float size,java.awt.Color color) throws IOException {stream.beginText();stream.setFont(f,size);stream.setNonStrokingColor(color);stream.newLineAtOffset(x,y);stream.showText(value);stream.endText();}
        static List<String> wrap(String value,float width,PDFont font,float size){List<String> lines=new ArrayList<>();for(String paragraph:value.split("\\R",-1)){StringBuilder line=new StringBuilder();for(int i=0;i<paragraph.length();){int point=paragraph.codePointAt(i);i+=Character.charCount(point);String next=new String(Character.toChars(point));try{if(line.length()>0&&font.getStringWidth(line+next)*size/1000>width){int space=line.lastIndexOf(" ");if(space>0){lines.add(line.substring(0,space));String rest=line.substring(space+1);line.setLength(0);line.append(rest);}else{lines.add(line.toString());line.setLength(0);}}}catch(IOException e){throw new IllegalStateException(e);}line.append(next);}lines.add(line.toString());}return lines;}
        public void close() throws IOException {if(stream!=null)stream.close();}
    }
}

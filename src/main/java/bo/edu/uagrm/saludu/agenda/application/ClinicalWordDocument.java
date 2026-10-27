package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.JsonNode;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.Locale;
import java.util.Map;
import org.apache.poi.util.Units;
import org.apache.poi.wp.usermodel.HeaderFooterType;
import org.apache.poi.xwpf.usermodel.*;
import org.springframework.stereotype.Component;

/** Renders only the single authorized historical snapshot supplied by PostgreSQL. */
@Component
public class ClinicalWordDocument {
    private static final String NAVY="1E3972";
    private static final Map<String,String> LABELS=Map.ofEntries(
        Map.entry("versionEsquema","Versión del esquema"),Map.entry("codigoEspecialidad","Código de especialidad"),
        Map.entry("signosVitales","Signos vitales y antropometría"),Map.entry("presionSistolica","Presión sistólica (mmHg)"),Map.entry("presionDiastolica","Presión diastólica (mmHg)"),
        Map.entry("frecuenciaCardiaca","Frecuencia cardíaca"),Map.entry("saturacionOxigeno","Saturación de oxígeno (%)"),Map.entry("peso","Peso (kg)"),Map.entry("talla","Talla (cm)"),
        Map.entry("temperatura","Temperatura (°C)"),Map.entry("habitos","Hábitos"),Map.entry("alimentacion","Alimentación"),Map.entry("cirugias","Cirugías"),
        Map.entry("patologicos","Patológicos"),Map.entry("quirurgicos","Quirúrgicos"),Map.entry("alergicos","Alérgicos"),Map.entry("medicacionHabitual","Medicación habitual"),
        Map.entry("oftalmologia","Oftalmología"),Map.entry("ginecologia","Ginecología"),Map.entry("educacionSalud","Educación en salud"),Map.entry("derivacion","Derivación"),Map.entry("sinObservaciones","Sin observaciones")
    );
    private static final Map<String,String> VALUES=Map.of("SI","Sí","NO","No","NINGUNO","Ninguno","PRESENTE","Presente","DESCONOCIDO","Desconocido","ADECUADA","Adecuada","INADECUADA","Inadecuada","CRONICO","Crónico","AGUDO","Agudo","SUBAGUDO","Subagudo");
    public byte[] render(JsonNode root,String purpose) throws IOException {
        try(var doc=new XWPFDocument();var out=new ByteArrayOutputStream()) {
            var header=doc.createHeader(HeaderFooterType.DEFAULT);
            var hp=header.createParagraph();hp.setAlignment(ParagraphAlignment.CENTER);
            logo(hp,"fcsh-uagrm-emblem.png"); hp.createRun().setText("   ");logo(hp,"centro-especialidades-emblem.png");
            var brand=header.createParagraph();brand.setAlignment(ParagraphAlignment.CENTER);var br=brand.createRun();br.setBold(true);br.setColor(NAVY);br.setText("CENTRO DE ESPECIALIDADES MÉDICAS");
            header.createParagraph().createRun().setText("Facultad de Ciencias de la Salud Humana · UAGRM");
            var footer=doc.createFooter(HeaderFooterType.DEFAULT).createParagraph();footer.setAlignment(ParagraphAlignment.CENTER);footer.createRun().setText("Documento clínico confidencial · Página ");footer.getCTP().addNewFldSimple().setInstr("PAGE");
            var e=root.path("encounter");var p=root.path("patient");boolean initial="INITIAL".equals(e.path("encounter_type").asText());
            heading(doc,initial?"Historia clínica de revisión médica":"Historia clínica de "+text(e.path("specialty")),true);
            heading(doc,"Identificación del paciente",false);
            row(doc,"Paciente",p.path("fullName"));row(doc,"Carnet",p.path("carnet"));row(doc,"Código de registro",p.path("registrationCode"));line(doc,"Fecha de nacimiento",date(p.path("birthDate"),false));row(doc,"Teléfono",p.path("phone"));row(doc,"Correo",p.path("email"));
            heading(doc,"Datos de la atención original",false);
            row(doc,"Identificador de atención",e.path("id"));line(doc,"Fecha de atención",date(e.path("occurred_at"),true));line(doc,"Fecha de cierre",date(e.path("closed_at"),true));row(doc,"Profesional",root.path("clinician"));line(doc,"Estado","Cerrada");
            row(doc,"Versión de ficha",e.path(initial?"reviewHistoryVersion":"specialtyHistoryVersion"));
            if(!initial){row(doc,"Especialidad",e.path("specialty"));row(doc,"Plantilla",e.path("template").path("id"));row(doc,"Versión de plantilla",e.path("template").path("version"));}
            row(doc,"Motivo de consulta",e.path("chief_complaint"));row(doc,"Evaluación clínica",e.path("assessment"));row(doc,"Indicaciones",e.path("instructions"));row(doc,"Seguimiento",e.path("follow_up_text"));
            heading(doc,"Diagnósticos de la atención",false);
            if(root.path("diagnoses").isEmpty())line(doc,"Diagnósticos","No registrado");
            for(var d:root.path("diagnoses"))line(doc,d.path("is_primary").asBoolean()?"Diagnóstico principal":"Diagnóstico",text(d.path("label")));
            var background=e.path("clinicalBackground");
            heading(doc,"Antecedentes generales vinculados a esta atención",false);
            if(background.isObject()){row(doc,"Versión de antecedentes",background.path("versionNo"));line(doc,"Registrados el",date(background.path("recordedAt"),true));fields(doc,"",background.path("data"));}
            else line(doc,"Antecedentes","Sin antecedentes generales vinculados a esta atención.");
            heading(doc,"Formulario clínico de la atención",false);
            var form=e.path(initial?"reviewHistory":"specialtyHistory");
            if(!form.isObject()||form.isEmpty())line(doc,"Formulario","No registrado");else {
                var fields=form.fields();while(fields.hasNext()){var f=fields.next();fields(doc,label(f.getKey()),f.getValue());}
            }
            heading(doc,"Mediciones registradas",false);
            if(root.path("measurements").isEmpty())line(doc,"Mediciones","No registrado");
            for(var v:root.path("measurements"))line(doc,text(v.path("label"))+" ("+text(v.path("code"))+")",text(v.path("value"))+" "+(v.path("unit").isNull()?"":v.path("unit").asText()));
            heading(doc,"Documentos disponibles de la atención",false);
            if(root.path("documents").isEmpty())line(doc,"Documentos","Sin documentos disponibles.");
            for(var d:root.path("documents")){row(doc,"Archivo",d.path("original_filename"));row(doc,"Clasificación",d.path("document_type_code"));row(doc,"Descripción",d.path("description"));line(doc,"Fecha de estudio",date(d.path("study_date"),false));}
            heading(doc,"Correcciones auditables · separadas del registro original",false);
            line(doc,"Alcance","Las adendas siguientes complementan la atención original sin reescribirla.");
            if(root.path("amendments").isEmpty())line(doc,"Adendas","Sin correcciones registradas.");
            for(var a:root.path("amendments")){heading(doc,"Adenda "+a.path("amendmentNo").asText(),false);row(doc,"Motivo de corrección",a.path("reason"));row(doc,"Contenido de la corrección",a.path("content"));row(doc,"Autor",a.path("createdByName"));row(doc,"Identificador del autor",a.path("createdBy"));line(doc,"Fecha de corrección",date(a.path("createdAt"),true));}
            heading(doc,"Procedencia y uso",false);line(doc,"Finalidad",purpose);line(doc,"Documento","Ficha individual autorizada. Los documentos adjuntos se descargan por separado mediante acceso privado.");
            doc.write(out);return out.toByteArray();
        }
    }
    private static void logo(XWPFParagraph p,String name) throws IOException {
        try(var input=ClinicalWordDocument.class.getResourceAsStream("/branding/"+name)){if(input==null)throw new IOException("Emblema institucional no disponible");try{p.createRun().addPicture(input,Document.PICTURE_TYPE_PNG,name,Units.toEMU(44),Units.toEMU(44));}catch(org.apache.poi.openxml4j.exceptions.InvalidFormatException e){throw new IOException(e);}}
    }
    private static String label(String key){return LABELS.getOrDefault(key,Character.toUpperCase(key.charAt(0))+key.substring(1).replaceAll("([a-záéíóúñ])([A-ZÁÉÍÓÚÑ])","$1 $2"));}
    private static String text(JsonNode v){if(v==null||v.isNull()||v.isMissingNode()||v.isTextual()&&v.asText().isBlank())return "No registrado";if(v.isBoolean())return v.asBoolean()?"Sí":"No";return VALUES.getOrDefault(v.asText(),v.asText());}
    private static String date(JsonNode v,boolean time){if(v.isNull()||v.isMissingNode()||v.asText().isBlank())return "No registrado";try{return time?OffsetDateTime.parse(v.asText()).atZoneSameInstant(ZoneId.of("America/La_Paz")).format(DateTimeFormatter.ofPattern("dd/MM/uuuu HH:mm:ss ' (Bolivia)'",Locale.forLanguageTag("es-BO"))):LocalDate.parse(v.asText()).format(DateTimeFormatter.ofPattern("dd/MM/uuuu"));}catch(java.time.format.DateTimeParseException ex){throw new IllegalArgumentException("Fecha clínica inválida",ex);}}
    private static void heading(XWPFDocument doc,String text,boolean main){var p=doc.createParagraph();p.setSpacingBefore(240);p.setSpacingAfter(100);if(main)p.setAlignment(ParagraphAlignment.CENTER);var r=p.createRun();r.setBold(true);r.setColor(NAVY);r.setFontSize(main?16:12);r.setText(text);}
    private static void row(XWPFDocument doc,String label,JsonNode value){line(doc,label,text(value));}
    private static void line(XWPFDocument doc,String label,String text){var p=doc.createParagraph();p.setSpacingAfter(70);var r=p.createRun();r.setBold(true);r.setText(label+": ");String[] lines=text.split("\\R",-1);var value=p.createRun();for(int i=0;i<lines.length;i++){if(i>0)value.addBreak();value.setText(lines[i]);}}
    private static void fields(XWPFDocument doc,String prefix,JsonNode node){
        if(node.isObject()){if(node.isEmpty())line(doc,prefix.isEmpty()?"Datos":prefix,"No registrado");node.fields().forEachRemaining(f->fields(doc,prefix.isEmpty()?label(f.getKey()):prefix+" · "+label(f.getKey()),f.getValue()));}
        else if(node.isArray()){if(node.isEmpty())line(doc,prefix,"No registrado");for(int i=0;i<node.size();i++)fields(doc,prefix+" "+(i+1),node.get(i));}
        else line(doc,prefix,text(node));
    }
}

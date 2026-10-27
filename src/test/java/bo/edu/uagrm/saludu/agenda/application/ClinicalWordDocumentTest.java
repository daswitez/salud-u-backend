package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayInputStream;
import org.apache.poi.xwpf.usermodel.XWPFDocument;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ClinicalWordDocumentTest {
    @Test void completeDocumentReopensWithHistoricalFieldsAndSeparateOrderedAdendas() throws Exception {
        var root=new ObjectMapper().readTree("""
        {"patient":{"fullName":"Paciente de prueba","carnet":"CI-1","birthDate":"2002-01-15"},
        "clinician":"Médica de prueba","encounter":{"id":"ficha-1","encounter_type":"SPECIALTY","specialty":"Oftalmología","occurred_at":"2026-10-25T02:30:00Z","closed_at":"2026-10-25T03:00:00Z","specialtyHistoryVersion":2,"template":{"id":"plantilla-original","version":1},"chief_complaint":"Motivo original","assessment":"Evaluación original","specialtyHistory":{"antecedentesPersonales":{"patologicos":"Antecedente propio del área"},"oftalmologia":{"sintomas":"Visión\\nborrosa","agudezaVisualDerecha":0.5},"signosVitales":{"peso":60},"lista":["dato uno","dato dos"]},"clinicalBackground":{"versionNo":4,"data":{"alergias":{"estado":"NINGUNO","elementos":[]},"habitos":{"tabaco":"NO"}}}},
        "diagnoses":[{"label":"Diagnóstico de prueba","is_primary":true}],"documents":[{"original_filename":"estudio.png","description":"Descripción privada"}],"measurements":[{"label":"Peso","code":"WEIGHT","value":60,"unit":"kg"}],
        "amendments":[{"amendmentNo":1,"reason":"Aclarar","content":"Primera corrección","createdByName":"Autor uno","createdAt":"2026-10-25T13:00:00Z"},{"amendmentNo":2,"reason":"Ampliar","content":"Segunda corrección","createdByName":"Autor dos","createdAt":"2026-10-25T14:00:00Z"}]}
        """);
        try(var doc=new XWPFDocument(new ByteArrayInputStream(new ClinicalWordDocument().render(root,"Consulta autorizada")))){
            String text=String.join("\n",doc.getParagraphs().stream().map(p->p.getText()).toList());
            for(String value:new String[]{"Paciente de prueba","15/01/2002","24/10/2026 22:30:00","Evaluación original","Diagnóstico de prueba","plantilla-original","Versión de plantilla: 1","Versión de antecedentes: 4","Antecedente propio del área","Visión","borrosa","dato uno","dato dos","60 kg","estudio.png","Motivo de corrección: Aclarar","Autor uno","25/10/2026 09:00:00","Consulta autorizada"})assertTrue(text.contains(value),value);
            assertTrue(text.indexOf("Evaluación original")<text.indexOf("Correcciones auditables"));assertTrue(text.indexOf("Primera corrección")<text.indexOf("Segunda corrección"));
            assertEquals(2,doc.getHeaderList().stream().mapToInt(h->h.getAllPictures().size()).sum());assertTrue(doc.getHeaderList().stream().anyMatch(h->h.getText().contains("UAGRM")));assertTrue(doc.getFooterList().getFirst().getText().contains("confidencial"));
        }
    }
    @Test void emptyOptionalSectionsAreExplicitAndNoDataIsInvented() throws Exception {
        var root=new ObjectMapper().readTree("{\"patient\":{},\"encounter\":{\"encounter_type\":\"INITIAL\"},\"amendments\":[],\"diagnoses\":[],\"documents\":[],\"measurements\":[]}");
        try(var doc=new XWPFDocument(new ByteArrayInputStream(new ClinicalWordDocument().render(root,"Consulta clínica autorizada")))){String content=String.join("\n",doc.getParagraphs().stream().map(p->p.getText()).toList());assertTrue(content.contains("Sin correcciones registradas"));assertTrue(content.contains("No registrado"));assertFalse(content.contains("null"));}
    }
}

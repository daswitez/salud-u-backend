package bo.edu.uagrm.saludu.agenda.application;

import static org.junit.jupiter.api.Assertions.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

class ClinicalJsonTest {
    private final ObjectMapper mapper = new ObjectMapper();
    @Test void spanishAndLegacyRequestsProduceTheSameCanonicalClinicalContent() throws Exception {
        var old = mapper.readTree("""
          {"schemaVersion":1,"allergies":{"status":"PRESENT","items":["YES","NONE","áéíóú"]},
           "habits":{"diet":"ADEQUATE","physicalActivity":"YES"}}
          """);
        var spanish = mapper.readTree("""
          {"versionEsquema":1,"alergias":{"estado":"PRESENTE","elementos":["YES","NONE","áéíóú"]},
           "habitos":{"alimentacion":"ADECUADA","actividadFisica":"SI"}}
          """);
        assertEquals(spanish, ClinicalJson.spanish(old));
        assertEquals(old, ClinicalJson.legacy(spanish));
        assertEquals(spanish, ClinicalJson.spanish(spanish));
        assertEquals(ClinicalBackgroundData.normalize(old), ClinicalBackgroundData.normalize(spanish));
    }
    @Test void textNullNumbersListsAndSpecialtyCatalogCodesRemainIntact() throws Exception {
        var old = mapper.readTree("""
          {"schemaVersion":1,"specialtyCode":"GYNECOLOGY","observations":"YES",
           "vitals":{"height":1.70,"weight":null},
           "gynecology":{"contraceptiveMethods":["IUD","CONDOM"],"symptoms":"NONE","previousSti":"NO"}}
          """);
        var spanish = ClinicalJson.spanish(old);
        assertEquals("GYNECOLOGY", spanish.path("codigoEspecialidad").asText());
        assertEquals("YES", spanish.path("observaciones").asText());
        assertEquals("NONE", spanish.path("ginecologia").path("sintomas").asText());
        assertEquals(mapper.readTree("[\"DIU\",\"PRESERVATIVO\"]"), spanish.path("ginecologia").path("metodosAnticonceptivos"));
        assertEquals(old, ClinicalJson.legacy(spanish));
        assertEquals(ClinicalHistoryData.specialty(old), ClinicalHistoryData.specialty(spanish));
        assertEquals(ClinicalHistoryData.review(old), ClinicalHistoryData.review(spanish));
    }
    @Test void conflictingAliasesAreRejectedInsteadOfDiscardingClinicalContent() throws Exception {
        var ambiguous = mapper.readTree("{\"vitals\":{\"weight\":10},\"signosVitales\":{\"peso\":20}}");
        assertThrows(AvailabilityException.class, () -> ClinicalHistoryData.review(ambiguous));
    }
}

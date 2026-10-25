package bo.edu.uagrm.saludu.agenda.application;

import static org.junit.jupiter.api.Assertions.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

class ClinicalHistoryDataTest {
    private final ObjectMapper mapper=new ObjectMapper();
    @Test void reviewMatchesLegacyTextNumberNullAndBooleanNormalization() throws Exception {
        var data=ClinicalHistoryData.review(mapper.readTree("""
          {"sex":"  F ","personalHistory":{"allergic":" Penicilina "},"habits":{"diet":"INVALID"},
          "vitals":{"bloodPressureSystolic":"120","temperature":"36.5","weight":"","height":null,"heartRate":"NaN","respiratoryRate":-1},
          "conduct":{"treatment":true,"referral":"true"},"observations":"  Hidratación "}
          """));
        assertEquals(1,data.path("versionEsquema").asInt());assertEquals("F",data.path("sexo").asText());
        assertEquals("Penicilina",data.path("antecedentesPersonales").path("alergicos").asText());
        assertTrue(data.path("habitos").path("alimentacion").isNull());assertTrue(data.path("examenFisico").path("abdomen").isNull());
        assertEquals(120,data.path("signosVitales").path("presionSistolica").asInt());
        assertEquals(36.5,data.path("signosVitales").path("temperatura").asDouble());
        assertEquals(0,data.path("signosVitales").path("peso").asInt());assertTrue(data.path("signosVitales").path("talla").isNull());
        assertTrue(data.path("signosVitales").path("frecuenciaCardiaca").isNull());assertTrue(data.path("signosVitales").path("frecuenciaRespiratoria").isNull());
        assertTrue(data.path("conducta").path("tratamiento").asBoolean());assertFalse(data.path("conducta").path("derivacion").asBoolean());
    }
    @Test void specialtyKeepsOrderedDistinctListsOnTheSharedFinalizeRoute() throws Exception {
        var data=ClinicalHistoryData.specialty(mapper.readTree("{\"specialtyCode\":\"GYNECOLOGY\",\"gynecology\":{\"contraceptiveMethods\":[\"IUD\",\"CONDOM\",\"IUD\",\"INVALID\"],\"menarcheAge\":\"12\"}}"));
        assertEquals(mapper.readTree("[\"DIU\",\"PRESERVATIVO\"]"),data.path("ginecologia").path("metodosAnticonceptivos"));
        assertEquals(12,data.path("ginecologia").path("edadMenarca").asInt());
        assertTrue(data.path("ginecologia").path("inicio").isNull());
    }
    @Test void limitsTextAndRejectsOutOfRangeMeasurements() throws Exception {
        var value=mapper.createObjectNode();value.put("observations","x".repeat(9000));value.putObject("vitals").put("weight",100001);
        var data=ClinicalHistoryData.review(value);assertEquals(8000,data.path("observaciones").asText().length());assertTrue(data.path("signosVitales").path("peso").isNull());
    }
}

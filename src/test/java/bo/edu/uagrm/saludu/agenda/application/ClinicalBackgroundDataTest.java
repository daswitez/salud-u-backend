package bo.edu.uagrm.saludu.agenda.application;

import static org.junit.jupiter.api.Assertions.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

class ClinicalBackgroundDataTest {
    private final ObjectMapper mapper = new ObjectMapper();

    @Test void preservesReferenceListsLegacyDetailsChoicesAndNullNormalization() throws Exception {
        var normalized = ClinicalBackgroundData.normalize(mapper.readTree("""
            {"schemaVersion":99,"allergies":{"status":"PRESENT","items":["  Uno ",null,5,"","Dos"]},
             "surgeries":{"status":"PRESENT","details":"  Operación  "},
             "medications":{"status":"NONE","items":["No conservar"]},
             "habits":{"diet":"REGULAR","tobacco":"INVALID"}}
            """));
        assertEquals(1, normalized.path("versionEsquema").asInt());
        assertEquals(mapper.readTree("[\"Uno\",\"Dos\"]"), normalized.path("alergias").path("elementos"));
        assertEquals("Operación", normalized.path("cirugias").path("elementos").get(0).asText());
        assertTrue(normalized.path("medicamentos").path("elementos").isEmpty());
        assertEquals("DESCONOCIDO", normalized.path("antecedentesFamiliares").path("estado").asText());
        assertEquals("", normalized.path("habitos").path("tabaco").asText());
        assertEquals("REGULAR", normalized.path("habitos").path("alimentacion").asText());
    }

    @Test void limitsFiftyItemsAndFiveHundredCharacters() {
        var source = mapper.createObjectNode();
        var items = source.putObject("allergies").put("status", "PRESENT").putArray("items");
        for (int i=0; i<60; i++) items.add("x".repeat(600));
        var normalized = ClinicalBackgroundData.normalize(source).path("alergias").path("elementos");
        assertEquals(50, normalized.size());
        assertEquals(500, normalized.get(0).asText().length());
    }
}

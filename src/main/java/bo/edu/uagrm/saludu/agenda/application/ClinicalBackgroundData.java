package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.List;

/** Characterized normalization previously performed by the Next route handler. */
public final class ClinicalBackgroundData {
    private ClinicalBackgroundData() {}

    public static JsonNode normalize(JsonNode source) {
        source=ClinicalJson.legacy(source);
        var json = JsonNodeFactory.instance;
        ObjectNode result = json.objectNode().put("schemaVersion", 1);
        for (String key : List.of("allergies", "personalConditions", "surgeries", "medications", "familyHistory")) {
            JsonNode value = source.path(key);
            String status = value.path("status").asText("");
            if (!List.of("PRESENT", "NONE", "UNKNOWN").contains(status)) status = "UNKNOWN";
            ObjectNode entry = json.objectNode().put("status", status);
            var items = entry.putArray("items");
            if (status.equals("PRESENT")) {
                if (value.path("items").isArray()) for (JsonNode item : value.path("items")) {
                    if (item.isTextual() && !item.asText().trim().isEmpty() && items.size() < 50) items.add(text(item.asText()));
                }
                if (items.isEmpty() && value.path("details").isTextual() && !value.path("details").asText().trim().isEmpty()) items.add(text(value.path("details").asText()));
            }
            result.set(key, entry);
        }
        ObjectNode habits = result.putObject("habits");
        habits.put("diet", choice(source.path("habits").path("diet"), List.of("ADEQUATE", "REGULAR", "INADEQUATE")));
        for (String key : List.of("physicalActivity", "tobacco", "alcohol")) habits.put(key, choice(source.path("habits").path(key), List.of("YES", "NO")));
        return ClinicalJson.spanish(result);
    }

    private static String text(String value) { String trimmed = value.trim(); return trimmed.substring(0, Math.min(500, trimmed.length())); }
    private static String choice(JsonNode value, List<String> allowed) { return value.isTextual() && allowed.contains(value.asText()) ? value.asText() : ""; }
}

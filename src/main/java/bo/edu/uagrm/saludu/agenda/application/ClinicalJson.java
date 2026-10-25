package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/** Lossless clinical key/code translation; free clinical text is never translated. */
public final class ClinicalJson {
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final JsonNode DICTIONARY;
    static {
        try (var stream = ClinicalJson.class.getResourceAsStream("/clinical-json-dictionary.json")) {
            if (stream == null) throw new IOException("Falta el diccionario clínico");
            DICTIONARY = MAPPER.readTree(stream);
        } catch (IOException exception) { throw new ExceptionInInitializerError(exception); }
    }
    private ClinicalJson() {}
    public static ObjectNode spanish(JsonNode value) { return (ObjectNode) translate(value, false, ""); }
    public static JsonNode legacy(JsonNode value) { return translate(value, true, ""); }
    private static JsonNode translate(JsonNode value, boolean reverse, String field) {
        if (value.isObject()) {
            ObjectNode result = MAPPER.createObjectNode();
            value.fields().forEachRemaining(entry -> {
                String legacyKey = reverseKey(entry.getKey());
                String target = reverse ? legacyKey : DICTIONARY.path("keys").path(legacyKey).asText(legacyKey);
                if (result.has(target)) throw new AvailabilityException(400, "No mezcles claves clínicas equivalentes en ambos idiomas.");
                result.set(target, translate(entry.getValue(), reverse, legacyKey));
            });
            return result;
        }
        if (value.isArray()) {
            var result = MAPPER.createArrayNode();
            value.forEach(item -> result.add(translate(item, reverse, field)));
            return result;
        }
        if (value.isTextual()) {
            var options = DICTIONARY.path("values").path(field);
            Map<String, String> inverse = new HashMap<>();
            options.fields().forEachRemaining(entry -> inverse.put(entry.getValue().asText(), entry.getKey()));
            String legacyValue = inverse.getOrDefault(value.asText(), value.asText());
            return MAPPER.getNodeFactory().textNode(reverse ? legacyValue : options.path(legacyValue).asText(value.asText()));
        }
        return value.deepCopy();
    }
    private static String reverseKey(String key) {
        var fields = DICTIONARY.path("keys").fields();
        while (fields.hasNext()) { var entry = fields.next(); if (entry.getValue().asText().equals(key)) return entry.getKey(); }
        return key;
    }
}

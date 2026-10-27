package bo.edu.uagrm.saludu.patients.application;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.Set;

/** A-02: contacto de emergencia del paciente en el contrato HTTP. relationship es un código de API del dominio parentesco. */
public record EmergencyContact(String fullName, String relationship, String phone) {
    public static final Set<String> RELATIONSHIPS = Set.of("PARENT", "SIBLING", "PARTNER", "GUARDIAN", "OTHER_RELATIVE", "OTHER");
    private static final Set<String> FIELDS = Set.of("fullName", "relationship", "phone");

    /** Exactamente {fullName, relationship, phone}, los tres con texto. */
    public static EmergencyContact parse(JsonNode node) {
        if (node == null || !node.isObject()) throw invalid();
        for (var names = node.fieldNames(); names.hasNext(); ) if (!FIELDS.contains(names.next())) throw invalid();
        String name = text(node.path("fullName"), 160), relationship = text(node.path("relationship"), 40), phone = text(node.path("phone"), 40);
        if (!RELATIONSHIPS.contains(relationship)) throw invalid();
        return new EmergencyContact(name, relationship, phone);
    }

    static EmergencyContact fromJson(JsonNode node) {
        return node == null || node.isNull() ? null
            : new EmergencyContact(node.path("fullName").asText(), node.path("relationship").asText(), node.path("phone").asText());
    }

    private static String text(JsonNode node, int max) {
        if (!node.isTextual() || node.textValue().isBlank() || node.textValue().trim().length() > max) throw invalid();
        return node.textValue().trim();
    }

    private static InvalidPatientException invalid() {
        return new InvalidPatientException("El contacto de emergencia necesita nombre (hasta 160 caracteres), teléfono (hasta 40) y parentesco: PARENT, SIBLING, PARTNER, GUARDIAN, OTHER_RELATIVE u OTHER.");
    }
}

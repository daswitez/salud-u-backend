package bo.edu.uagrm.saludu.patients.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;

/**
 * A-03: respuesta a los dos textos vigentes. Los términos solo se aceptan; investigación es Sí o No, sin valor por defecto.
 * Las versiones son las que la persona leyó: si ya no son las vigentes, la base rechaza la respuesta.
 */
public record ConsentAnswer(String termsVersion, Boolean termsAccepted, String researchVersion, Boolean researchAccepted) {
    public ConsentAnswer validated() {
        if (!Boolean.TRUE.equals(termsAccepted)) throw new AvailabilityException(400, "Debes aceptar los términos de uso y el aviso de privacidad para continuar.");
        if (researchAccepted == null) throw new AvailabilityException(400, "Responde Sí o No a la pregunta sobre investigación para continuar.");
        if (blank(termsVersion) || blank(researchVersion)) throw new AvailabilityException(400, "Indica la versión de los textos que se leyeron.");
        return this;
    }

    private static boolean blank(String value) { return value == null || value.isBlank(); }
}

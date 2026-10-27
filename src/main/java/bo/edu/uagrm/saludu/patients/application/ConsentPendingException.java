package bo.edu.uagrm.saludu.patients.application;

/** A-03: el paciente no respondió los textos vigentes; responde 422 con code CONSENTIMIENTO_PENDIENTE. */
public class ConsentPendingException extends RuntimeException {
    public static final String CODE = "CONSENTIMIENTO_PENDIENTE";

    public ConsentPendingException() {
        super("Antes de continuar, el paciente debe aceptar los términos de uso y responder Sí o No sobre investigación.");
    }
}

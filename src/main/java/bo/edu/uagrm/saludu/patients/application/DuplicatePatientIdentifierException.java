package bo.edu.uagrm.saludu.patients.application;

public class DuplicatePatientIdentifierException extends RuntimeException {
    public DuplicatePatientIdentifierException() {
        super("El carnet o código de registro ya existe.");
    }
}

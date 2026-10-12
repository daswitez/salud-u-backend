package bo.edu.uagrm.saludu.patients.application;

public class InvalidPatientException extends RuntimeException {
    public InvalidPatientException(String message) {
        super(message);
    }
}

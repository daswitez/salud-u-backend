package bo.edu.uagrm.saludu.identity.application;

public class InvalidCredentialsException extends RuntimeException {
    public InvalidCredentialsException() {
        super("Las credenciales no son válidas.");
    }
}

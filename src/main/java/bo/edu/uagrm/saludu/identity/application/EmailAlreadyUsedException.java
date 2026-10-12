package bo.edu.uagrm.saludu.identity.application;

public class EmailAlreadyUsedException extends RuntimeException {
    public EmailAlreadyUsedException() {
        super("El correo ya está asociado a otra cuenta.");
    }
}

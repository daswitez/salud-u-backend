package bo.edu.uagrm.saludu.agenda.application;

public class AvailabilityException extends RuntimeException {
    private final int status;

    public AvailabilityException(int status, String message) {
        super(message);
        this.status = status;
    }

    public int status() {
        return status;
    }
}

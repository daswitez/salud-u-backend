package bo.edu.uagrm.saludu.patients.application;

public class PatientNotFoundException extends RuntimeException {
    public PatientNotFoundException() {
        super("Estudiante no encontrado.");
    }
}

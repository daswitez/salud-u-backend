package bo.edu.uagrm.saludu.patients.api;

import com.fasterxml.jackson.databind.JsonNode;
import java.time.LocalDate;
import java.util.UUID;

public record PatientRequest(
    String fullName, String carnet, String registrationCode, LocalDate birthDate, String phone, String email,
    UUID careerId, String academicPeriod, LocalDate enrollmentStart, String sex,
    /** A-02: ausente (null) no toca el contacto; JSON null (NullNode) lo elimina; objeto lo guarda. */
    JsonNode emergencyContact,
    /** A-03: opcional mientras dure la puesta en marcha; si llega, se registra con vía ADMINISTRACION. */
    bo.edu.uagrm.saludu.patients.application.ConsentAnswer consents
) {
}

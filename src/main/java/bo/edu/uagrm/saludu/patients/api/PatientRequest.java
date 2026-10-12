package bo.edu.uagrm.saludu.patients.api;

import java.time.LocalDate;
import java.util.UUID;

public record PatientRequest(
    String fullName, String carnet, String registrationCode, LocalDate birthDate, String phone, String email,
    UUID careerId, String academicPeriod, LocalDate enrollmentStart
) {
}

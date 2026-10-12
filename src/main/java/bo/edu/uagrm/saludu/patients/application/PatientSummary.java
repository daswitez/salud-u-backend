package bo.edu.uagrm.saludu.patients.application;

import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

public record PatientSummary(
    UUID id, String carnet, String registrationCode, String fullName, LocalDate birthDate, String phone, String email,
    String academicStatus, Instant createdAt, Instant updatedAt, Career career, Enrollment enrollment
) {
    public record Career(UUID id, String code, String name) {
    }

    public record Enrollment(UUID id, String academicPeriod, LocalDate startedOn, String status) {
    }
}

package bo.edu.uagrm.saludu.scheduling.application;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

public record AcademicPeriod(UUID id, String name, String type, LocalDate startDate, LocalDate endDate, OffsetDateTime createdAt) {}

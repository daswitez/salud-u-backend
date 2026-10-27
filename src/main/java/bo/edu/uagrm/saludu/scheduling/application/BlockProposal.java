package bo.edu.uagrm.saludu.scheduling.application;

import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** O-07: propuesta de bloqueo con sus reprogramaciones (contrato HTTP en inglés). startTime null = día completo. */
public record BlockProposal(UUID id, UUID staffId, String staffName, LocalDate date, LocalTime startTime, LocalTime endTime,
    String label, String status, UUID blockId, int pendingAppointments, OffsetDateTime createdAt, OffsetDateTime appliedAt,
    List<ScheduleSuggestion> reschedules) {}

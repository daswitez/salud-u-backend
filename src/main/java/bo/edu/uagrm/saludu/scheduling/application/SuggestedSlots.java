package bo.edu.uagrm.saludu.scheduling.application;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Cupos sugeridos para una solicitud, con el contrato HTTP en inglés. */
public record SuggestedSlots(UUID requestId, String appointmentType, String priority, String modelVersion, double waitWeight,
    double occupancyWeight, List<Slot> slots) {

    public record Slot(int rank, UUID slotId, OffsetDateTime startsAt, OffsetDateTime endsAt, UUID staffId, String staffName,
        UUID specialtyId, String specialtyName, int freePlaces, long waitDays, double expectedOccupancy, double estimatedAttendance,
        String attendanceSource, double score, String explanation) {}
}

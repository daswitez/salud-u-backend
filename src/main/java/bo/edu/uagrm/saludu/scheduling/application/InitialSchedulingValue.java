package bo.edu.uagrm.saludu.scheduling.application;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** specialtyId null es el valor del área; expectedDailyDemand null significa "igual a la capacidad publicada" (DV-10). */
public record InitialSchedulingValue(UUID specialtyId, String specialtyName, String periodType, BigDecimal expectedDailyDemand,
    BigDecimal expectedAttendance, int appointmentWeight, boolean isDefault, OffsetDateTime updatedAt) {}

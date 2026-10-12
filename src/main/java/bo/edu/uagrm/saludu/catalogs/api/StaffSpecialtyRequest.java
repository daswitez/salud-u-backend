package bo.edu.uagrm.saludu.catalogs.api;

import jakarta.validation.constraints.NotNull;
import java.time.LocalDate;
import java.util.UUID;

public record StaffSpecialtyRequest(@NotNull UUID staffMemberId, @NotNull UUID specialtyId, LocalDate activeFrom, LocalDate activeTo) {
}

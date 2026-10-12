package bo.edu.uagrm.saludu.catalogs.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import java.util.UUID;

public record StaffRequest(@NotNull UUID principalId, @NotBlank @Pattern(regexp = "[A-Za-z0-9_-]{2,50}") String staffCode, boolean active) {
}

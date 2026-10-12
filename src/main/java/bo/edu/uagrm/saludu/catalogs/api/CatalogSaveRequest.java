package bo.edu.uagrm.saludu.catalogs.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.util.UUID;

public record CatalogSaveRequest(
    UUID id,
    @NotBlank @Pattern(regexp = "[A-Za-z0-9_]{2,50}") String code,
    @NotBlank @Size(max = 160) String name,
    boolean active
) {
}

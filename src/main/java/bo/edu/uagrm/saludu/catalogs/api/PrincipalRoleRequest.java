package bo.edu.uagrm.saludu.catalogs.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;

public record PrincipalRoleRequest(
    @NotBlank @Pattern(regexp = "ADMINISTRATIVE|REVIEW_DOCTOR|SPECIALIST|STUDENT|AUDITOR|REPORTING_OFFICER") String role,
    boolean active
) {
}

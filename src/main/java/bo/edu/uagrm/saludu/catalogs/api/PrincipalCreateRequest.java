package bo.edu.uagrm.saludu.catalogs.api;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.util.List;

public record PrincipalCreateRequest(
    @NotBlank @Email String email,
    @NotBlank @Size(max = 160) String displayName,
    @NotBlank @Size(min = 12, max = 256) String password,
    @NotEmpty List<@Pattern(regexp = "ADMINISTRATIVE|REVIEW_DOCTOR|SPECIALIST|STUDENT|AUDITOR|REPORTING_OFFICER") String> roles
) {
}

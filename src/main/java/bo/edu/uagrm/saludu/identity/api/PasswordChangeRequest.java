package bo.edu.uagrm.saludu.identity.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record PasswordChangeRequest(
    @NotBlank @Size(max = 128) String currentPassword,
    @NotBlank @Size(min = 12, max = 128) String newPassword
) {
}

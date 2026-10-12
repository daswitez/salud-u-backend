package bo.edu.uagrm.saludu.identity.api;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record ProfileUpdateRequest(
    @NotBlank @Size(max = 160) String displayName,
    @NotBlank @Email @Size(max = 254) String email,
    @NotBlank @Size(max = 128) String currentPassword
) {
}

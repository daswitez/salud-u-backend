package bo.edu.uagrm.saludu.identity.api;

import jakarta.validation.constraints.Size;

/** Código de 6 dígitos de la aplicación o código de recuperación. */
public record SecondFactorRequest(@Size(max = 16) String code, @Size(max = 64) String recoveryCode) {
}

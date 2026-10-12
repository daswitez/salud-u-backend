package bo.edu.uagrm.saludu.shared.persistence;

import java.util.Set;
import java.util.UUID;

public record DatabaseActor(UUID id, Set<String> roles) {
    public DatabaseActor {
        if (id == null) {
            throw new IllegalArgumentException("El actor de base de datos es obligatorio.");
        }
        roles = roles == null ? Set.of() : Set.copyOf(roles);
        if (roles.stream().anyMatch(role -> role == null || !role.matches("[A-Z_]{2,64}"))) {
            throw new IllegalArgumentException("Los roles del actor no son válidos.");
        }
    }
}

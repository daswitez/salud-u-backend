package bo.edu.uagrm.saludu.identity.infrastructure;

import java.security.Principal;
import java.util.List;
import java.util.UUID;

public record SessionPrincipal(UUID id, String email, String displayName, List<String> roles) implements Principal {
    public SessionPrincipal {
        roles = List.copyOf(roles);
    }

    @Override
    public String getName() {
        return email;
    }
}

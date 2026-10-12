package bo.edu.uagrm.saludu.catalogs.application;

import java.util.List;
import java.util.UUID;

public record AdministrativePrincipal(UUID id, String email, String displayName, boolean active, List<String> roles) {
}
